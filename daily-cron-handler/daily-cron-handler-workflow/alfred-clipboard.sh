#!/usr/local/bin/bash
# This is a script that provides infinite history to get around Alfred's 3-month limit.
# It works by regularly backing up and appending the items in the alfred db to a
# sqlite database in the user's home folder. It also provides search functionality.

# https://www.alfredforum.com/topic/10969-keep-clipboard-history-forever/?tab=comments#comment-68859
# https://www.reddit.com/r/Alfred/comments/cde29x/script_to_manage_searching_backing_up_and/

# Example Usage:
#    alfred-clipboard.sh backup
#    alfred-clipboard.sh status
#    alfred-clipboard.sh shell
#    alfred-clipboard.sh dump > ~/Desktop/clipboard_db.sqlite3
#    alfred-clipboard.sh search 'some_string' --separator=, --limit=2 --fields=ts,item,app

shopt -s extglob
set +o pipefail

# *************************************************************************
# --------------------------- Why this exists -----------------------------
# *************************************************************************

# I'd be willing to pay >another $30 on top of my existing Legendary license for 
# unlimited clipboard history, and I fully accept any CPU/Memory hit necessary to get it.
#
# I use Clipboard History as a general buffer for everything in my life, 
# and losing everything beyond 3 months is a frequent source of headache.  
# Here's a small sample of a few recent things I've lost due to history expiring:
#
#  - flight confirmation details
#  - commit summaries with commit ids (detached commits that are hard to find due to deleted branches)
#  - important UUIDs
#  - ssh public keys
#  - many many many file paths (lots of obscure config file paths that I never bother to remember)
#  - entire config files 
#  - blog post drafts
#  - comments on social media
#  - form fields on websites
#
# It's always stuff that I don't realize at the time would be important later
# so it would be pointless to try and use snippets to solve this issue.
#
# Having a massive index of every meaningful string that's passed through my 
# brain is incredibly useful. In fact I rely on it so much that I'd even 
# willing to manage an entire separate server with Elasticsearch/Redis 
# full-text search to handle storage and indexing beyond 3 months (if 
# that's really what it takes to keep history indefinitely).
#
# If needed you could hide "6 months" "12 months" and "unlimited" behind an 
# "Advanced settings" pane and display a big warning about potential performance 
# downsides.
#
# For now I just periodically back up `~/Library/Application Support/Alfred 3/Databases/clipboard.alfdb` 
# to a separate folder, and merge the rows in it with a main database.  This at 
# least allows me to query further back by querying the merged database directly.
#  Maybe I'll build a workflow to do that if I have time, but no promises.
#
# I've created a script that handles the backup of the db, merging it with an
# infinite-history sqlite db in my home folder, and searching functionality.
# https://gist.github.com/pirate/6551e1c00a7c4b0c607762930e22804c
#
# I also tried hacking around the limit by changing the Alfred binary directly
# but unfortunately I was only able to find the limit in the .nib file (which
# is useless as it's just the GUI definition).
# I'd have to properly decompile Alfred it to find the actual limit logic...
# $ ggrep --byte-offset --only-matching --text '3 Months' \
#       '/Applications/Alfred 3.app/Contents/Frameworks/Alfred Framework.framework/Versions/A/Resources/AlfredFeatureClipboard.nib'
# 12590:3 Months
#
# (Now I just have to convince the Google Chrome team to also allow storing 
# browser history longer than 3 months... then the two biggest sources of 
# data-loss pain in my life will be eliminated).


# *************************************************************************
# --------------------------- Config Options ------------------------------
# *************************************************************************

BACKUP_DATA_DIR="${BACKUP_DATA_DIR:-$HOME/Clipboard}"
ALFRED_DATA_DIR="${ALFRED_DATA_DIR:-$HOME/Library/Application Support/Alfred/Databases}"
ALFRED_DB_NAME="${ALFRED_DB_NAME:-clipboard.alfdb}"
BACKUP_DB_NAME="${BACKUP_DB_NAME:-$(date +'%Y-%m-%d_%H:%M:%S').sqlite3}"
MERGED_DB_NAME="${MERGED_DB_NAME:-all.sqlite3}"

# uncomment the second option if you also to store the duplicate item history
# entries for whenever the same value was copied again at a different time
UNIQUE_FILTER="${UNIQUE_FILTER:-'latest.item = item'}"
# UNIQUE_FILTER="${UNIQUE_FILTER:-'latest.item = item AND latest.ts = ts'}"


# *************************************************************************
# -------------------------------------------------------------------------
# *************************************************************************


ALFRED_DB="$ALFRED_DATA_DIR/$ALFRED_DB_NAME"
BACKUP_DB="$BACKUP_DATA_DIR/$BACKUP_DB_NAME"
MERGED_DB="$BACKUP_DATA_DIR/$MERGED_DB_NAME"
MERGE_QUERY="
    /* Delete any items that are the same in both databases */
    DELETE FROM merged_db.clipboard
        WHERE EXISTS(
            SELECT 1 FROM latest_db.clipboard latest
            WHERE latest.item = item
        );
    /* Insert all items from the latest_db backup  */
    INSERT INTO merged_db.clipboard
        SELECT * FROM latest_db.clipboard;
"

backup_rows=0
existing_rows=0
merged_rows=0

function backup_alfred_db {
    echo "[+] Backing up Alfred Clipboard History DB..."
    cp "$ALFRED_DB" "$BACKUP_DB"
    backup_rows=$(sqlite3 "$BACKUP_DB" 'select count(*) from clipboard;')
    echo "    √ Read     $backup_rows items from $ALFRED_DB_NAME"
    echo "    √ Wrote    $backup_rows items to $BACKUP_DB_NAME"
}

function init_master_db {
    echo -e "\n[+] Initializing new clipboard database with $backup_rows items..."
    cp "$BACKUP_DB" "$MERGED_DB"
    echo "    √ Copied new db $MERGED_DB"
    echo
    sqlite3 "$MERGED_DB" ".schema" | sed 's/^/    /'
}

function remove_backup_db {
    echo -e "\n[-] removing the interim created db"
    rm "$BACKUP_DB"
    echo "    √ removed interim db $BACKUP_DB"
}

function update_master_db {
    existing_rows=$(sqlite3 "$MERGED_DB" 'select count(*) from clipboard;')

    echo -e "\n[*] Updating Master Clipboard History DB..."
    echo "    √ Read     $existing_rows existing items from "$(basename "$MERGED_DB")
    sqlite3 "$MERGED_DB" "
        attach '$MERGED_DB' as merged_db;
        attach '$BACKUP_DB' as latest_db;
        BEGIN;
        $MERGE_QUERY
        COMMIT;
        detach latest_db;
        detach merged_db;
    "
    merged_rows=$(sqlite3 "$MERGED_DB" 'select count(*) from clipboard;')
    new_rows=$(( merged_rows - existing_rows ))
    echo "    √ Merged   $backup_rows items from backup into Master DB"
    echo "    √ Added    $new_rows new items to Master DB"
    echo "    √ Wrote    $merged_rows total items to $MERGED_DB_NAME"
}

# *************************************************************************
# -------------------------------------------------------------------------
# *************************************************************************

function summary {
    backup_rows=$(sqlite3 "$BACKUP_DB" 'select count(*) from clipboard;')
    existing_rows=$(sqlite3 "$MERGED_DB" 'select count(*) from clipboard;')
    merged_rows=$(sqlite3 "$MERGED_DB" 'select count(*) from clipboard;')
    echo "    Original   $ALFRED_DB ($backup_rows items)"
    echo "    Backup     $BACKUP_DB ($backup_rows items)"
    echo "    Master     $MERGED_DB ($merged_rows items)"
}

function backup {
    backup_alfred_db
    [[ -f "$MERGED_DB" ]] || init_master_db
    update_master_db

    echo -e "\n[√] Done backing up clipboard history."
    summary

    remove_backup_db
}

function print_help {
    echo "Usage: TODO"
}

function unrecognized {
    echo "Error: Unrecognized argument $1" >&2
    print_help
    exit 2
}

# *************************************************************************
# -------------------------------------------------------------------------
# *************************************************************************

function main {
    COMMAND=''
    declare -a ARGS=()
    declare -A KWARGS=( [style]='csv' [separator]="|" [fields]='item' [verbose]='' [limit]=10)

    mkdir -p "$BACKUP_DATA_DIR"

    while (( "$#" )); do
        case "$1" in
            help|-h|--help)
                COMMAND='help'
                print_help
                exit 0;;

            -v|--verbose)
                KWARGS[verbose]='yes'
                shift;;

            -j|--json)
                KWARGS[style]='json'
                shift;;

            --separator|--separator=*)
                if [[ "$1" == *'='* ]]; then
                    KWARGS[separator]="${1#*=}"
                else
                    shift
                    KWARGS[separator]="$1"
                fi
                shift;;

            -s|--style|-s=*|--style=*)
                if [[ "$1" == *'='* ]]; then
                    KWARGS[style]="${1#*=}"
                else
                    shift
                    KWARGS[style]="$1"
                fi
                shift;;

            -l|--limit|-l=*|--limit=*)
                if [[ "$1" == *'='* ]]; then
                    KWARGS[limit]="${1#*=}"
                else
                    shift
                    KWARGS[limit]="$1"
                fi
                shift;;

            -f|--fields|-f=*|--fields=*)
                if [[ "$1" == *'='* ]]; then
                    KWARGS[fields]="${1#*=}"
                else
                    shift
                    KWARGS[fields]="$1"
                fi
                shift;;

            +([a-z]))
                if [[ "$COMMAND" ]]; then
                    ARGS+=("$1")
                else
                    COMMAND="$1"
                fi
                shift;;

            --)
                shift;
                ARGS+=("$@")
                break;;
            *)
                [[ "$COMMAND" != "search" ]] && unrecognized "$1"
                ARGS+=("$1")
                shift;;
        esac
    done

    # echo "COMMAND=$COMMAND"
    # echo "ARGS=${ARGS[*]}"
    # for key in "${!KWARGS[@]}"; do
    #     echo "$key=${KWARGS[$key]}"
    # done

    if [[ "$COMMAND" == "status" ]]; then
        summary
    elif [[ "$COMMAND" == "backup" ]]; then
        backup
    elif [[ "$COMMAND" == "shell" ]]; then
        sqlite3 "$MERGED_DB"
    elif [[ "$COMMAND" == "dump" ]]; then
        sqlite3 "$MERGED_DB" ".dump"
    elif [[ "$COMMAND" == "search" ]]; then
        if [[ "${KWARGS[style]}" == "json" ]]; then
            sqlite3 "$MERGED_DB" "
                SELECT '{\"items\": [' || group_concat(match) || ']}'
                FROM (
                    SELECT json_object(
                        'valid', 1,
                        'uuid', ts,
                        'title', substr(item, 1, 120),
                        'arg', item
                    ) as match
                    FROM clipboard
                    WHERE item LIKE '%${ARGS[*]}%'
                    ORDER BY ts DESC
                    LIMIT ${KWARGS[limit]}
                );
            "
        else
            sqlite3 -separator "${KWARGS[separator]}" "$MERGED_DB" "
                SELECT ${KWARGS[fields]}
                FROM clipboard
                WHERE item LIKE '%${ARGS[*]}%'
                ORDER BY ts DESC
                LIMIT ${KWARGS[limit]};
            "
        fi

    else
        unrecognized "$COMMAND"
    fi
}

main "$@"