#!/bin/bash
# Deploy only the listed public files from each repository's production branch.
set -euo pipefail
umask 077
export PATH="/usr/local/bin:/usr/bin:/bin:${PATH:-}"
export GIT_TERMINAL_PROMPT=0

state_dir="$HOME/.finance-deploy"
mkdir -p "$state_dir"
exec 9>"$state_dir/sync.lock"
flock -n 9 || exit 0

sync_site() (
    local repo="$1" site="$2" initial_commit="$3" handler="$4"
    local root="$HOME/$site/public_html"
    local cache="$state_dir/$repo.git" previous target status file backup=''
    local work
    local -a files=("$handler" index.html) changed=() published=()

    [[ -d "$root" ]] || { echo "Каталог сайта не найден: $root" >&2; exit 1; }
    [[ -d "$cache/objects" ]] || git init --bare --quiet "$cache"
    timeout 45s git -C "$cache" fetch --quiet --no-tags \
        "https://github.com/Gandaev-a/$repo.git" refs/heads/production
    target=$(git -C "$cache" rev-parse --verify 'FETCH_HEAD^{commit}')
    previous=$(git -C "$cache" rev-parse -q --verify refs/timeweb/deployed || printf '%s\n' "$initial_commit")
    [[ "$target" != "$previous" ]] || exit 0
    if ! git -C "$cache" merge-base --is-ancestor "$previous" "$target"; then
        echo "$site: production должна продолжать историю последней выкладки" >&2
        exit 1
    fi
    if [[ $(stat -c %d "$root") != "$(stat -c %d "$state_dir")" ]]; then
        echo "$site: каталог сайта и каталог выкладки на разных файловых системах" >&2
        exit 1
    fi

    work=$(mktemp -d "$state_dir/staging.XXXXXXXX")
    cleanup() {
        status=$?
        if (( status != 0 )); then
            for file in "${published[@]}"; do
                if cp -p -- "$backup/$file" "$work/restore" &&
                    mv -T -- "$work/restore" "$root/$file"; then
                    echo "$site: восстановлен $file" >&2
                else
                    echo "$site: восстановите $file из $backup" >&2
                fi
            done
        fi
        rm -rf -- "$work"
    }
    trap cleanup EXIT
    trap 'exit 1' INT TERM

    for file in "${files[@]}"; do
        [[ -f "$root/$file" && ! -L "$root/$file" ]] ||
            { echo "$site: ожидается обычный файл $file" >&2; exit 1; }
        git -C "$cache" show "$target:$file" > "$work/$file"
        git -C "$cache" show "$previous:$file" > "$work/$file.previous"
        if cmp -s -- "$work/$file" "$root/$file"; then
            continue
        fi
        if ! cmp -s -- "$work/$file.previous" "$root/$file"; then
            echo "$site: $file изменён на хостинге, выкладка остановлена" >&2
            exit 1
        fi
        chmod --reference="$root/$file" "$work/$file"
        changed+=("$file")
    done

    if (( ${#changed[@]} > 0 )); then
        php -l "$work/$handler"
        mkdir -p "$state_dir/backups"
        backup=$(mktemp -d "$state_dir/backups/$repo.XXXXXXXX")
        for file in "${changed[@]}"; do
            cp -p -- "$root/$file" "$backup/$file"
            cmp -s -- "$work/$file.previous" "$backup/$file" ||
                { echo "$site: $file изменился в ходе подготовки выкладки" >&2; exit 1; }
        done
        for file in "${changed[@]}"; do
            published+=("$file")
            mv -T -- "$work/$file" "$root/$file"
        done
    fi

    git -C "$cache" update-ref refs/timeweb/deployed "$target"
    echo "$site: опубликован $target"
)

sync_site tulpar-finance Avtozalog-kazan f4282aa49a9413f9592b31e323d14424e1c9f3c1 send.php
sync_site krsk_finance Avtozalog-krsk bf791c7c8b6cb069af44e1fb414989d65f27a1f5 submit.php
