#!/bin/bash
set -e

branch="$1"
merge_base=$(git merge-base origin/master "origin/$branch")

# Make lists of PRs that were merged into each branch. Use first parent here, or else
# we'll get weird things like seeing older master that was merged into a PR branch
# that was then merged into master.
git log "$merge_base..origin/master" --first-parent --oneline > master-log.txt
git log "$merge_base..origin/$branch" --first-parent --oneline > "$branch-log.txt"

# Search for PR numbers in commit messages. First variant is normal merge, and second
# variant is squashed.
find_prs=(sed -n "s/^.*Merge pull request #\([[:digit:]]\+\).*$/\1/p;
                  s/^.*(#\([[:digit:]]\+\))$/\1/p")

"${find_prs[@]}" master-log.txt | sort -rn > master-prs.txt
"${find_prs[@]}" "$branch-log.txt" | sort -rn > "$branch-prs.txt"

# Find all master PRs that are not in branch by calculating differences of two PR lists.
grep -f "$branch-prs.txt" -F -x -v master-prs.txt > "$branch-diff-prs.txt"

rm "$branch-report.tsv" ||:

echo "$(wc -l < "$branch-diff-prs".txt) PRs differ between $branch and master."

for pr in $(cat "$branch-diff-prs.txt")
do
    # Download PR info from github.
    file="pr$pr.json"
    if ! [ -f "$file" ]
    then
        if ! curl -H "Authorization: token $GITHUB_TOKEN" \
                -sSf "https://api.github.com/repos/ClickHouse/ClickHouse/pulls/$pr" \
                > "$file"
        then
            >&2 cat "$file"
            rm "$file"
            break
        fi
        sleep 0.5
    fi

    if ! [ "$pr" == "$(jq -r .number "$file")" ]
    then
        >&2 echo "Got wrong data for PR #$pr (please check and remove '$file')."
        continue
    fi

    action="skip"

    # First, check the changelog category. We port all bugfixes.
    if jq -r .body "$file" | grep -i "^- bug[ -]*fix" > /dev/null
    then
        action="backport"
    fi

    # Next, check the tag. They might override the decision.
    matched_labels=()
    for label in $(jq -r .labels[].name "$file")
    do
        label_action=""
        case "$label" in
            pr-must-backport | "v$branch-must-backport")
                label_action="backport"
                ;;
            pr-no-backport | "v$branch-no-backport")
                label_action="no-backport"
                ;;
            "v$branch-conflicts")
                label_action="conflict"
                ;;
            "v$branch" | "v$branch-backported")
                label_action="done"
                ;;
        esac
        if [ "$label_action" != "" ]
        then
            action="$label_action"
            matched_labels+=("$label")
        fi
    done

    # Show an error if there are conflicting labels.
    if [ ${#matched_labels[@]} -gt 1 ]
    then
        >&2 echo "PR #$pr has conflicting labels: ${matched_labels[*]}"
        continue
    fi

    url="https://github.com/ClickHouse/ClickHouse/pull/$pr"
    printf "%s\t%s\t%s\t%s\n" "$action" "$pr" "$url" "$file" >> "$branch-report.tsv"
    if [ "$action" == "backport" ]
    then
        printf "%s\t%s\n" "$action" "$url"
    fi
done

