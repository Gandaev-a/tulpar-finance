#!/bin/bash
# Выкладка сайта на хостинг Timeweb по FTP.
#
#   bash deploy.sh
#
# Пароль FTP и токен бота вводятся с клавиатуры, в файлы на этом компьютере
# не записываются и в список процессов не попадают.

set -u
cd "$(dirname "$0")" || exit 1

DOMAIN="avtozalog-kazan.ru"
FILES="index.html privacy.html consent.html terms.html tariffs.html dogovor.html docs.css send.php robots.txt sitemap.xml"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"

bold "Выкладка $DOMAIN на Timeweb"
echo "Данные FTP — в панели Timeweb, раздел «Доступ по FTP»."
echo

read -r -p "FTP-хост (вида vh123.timeweb.ru): " FTP_HOST
FTP_HOST=$(printf '%s' "$FTP_HOST" | sed -e 's#^ftp://##' -e 's#/.*$##' -e 's/[[:space:]]//g')
[ -z "$FTP_HOST" ] && { bad "хост не указан"; exit 1; }

read -r -p "FTP-логин [ch737711_1]: " FTP_USER
FTP_USER=${FTP_USER:-ch737711_1}

read -r -s -p "FTP-пароль (ввод не отображается): " FTP_PASS; echo
[ -z "$FTP_PASS" ] && { bad "пароль не указан"; exit 1; }

NETRC="$TMP/netrc"
printf 'machine %s\nlogin %s\npassword %s\n' "${FTP_HOST%%:*}" "$FTP_USER" "$FTP_PASS" > "$NETRC"
chmod 600 "$NETRC"
unset FTP_PASS

ftpc() { curl -sS --netrc-file "$NETRC" $TLS "$@"; }

# ---------- подключение ----------
bold "Подключение"
TLS="--ssl-reqd"
if ! ftpc --list-only "ftp://$FTP_HOST/" > "$TMP/root.txt" 2> "$TMP/err.txt"; then
  TLS=""
  if ftpc --list-only "ftp://$FTP_HOST/" > "$TMP/root.txt" 2> "$TMP/err.txt"; then
    warn "сервер не принял шифрованное соединение, работаю без TLS"
  else
    bad "не удалось подключиться:"
    sed 's/^/    /' "$TMP/err.txt"
    echo "    Проверьте хост, логин и пароль в панели Timeweb."
    exit 1
  fi
else
  ok "шифрованное соединение установлено"
fi

tr -d '\r' < "$TMP/root.txt" > "$TMP/root.clean"
if grep -qx "$DOMAIN" "$TMP/root.clean"; then
  REMOTE="$DOMAIN/public_html"
elif grep -qx "public_html" "$TMP/root.clean"; then
  REMOTE="public_html"
else
  REMOTE=""
fi

echo "  Содержимое FTP:"
sed 's/^/    · /' "$TMP/root.clean"
read -r -p "Папка сайта на сервере [${REMOTE:-корень}]: " ANS
REMOTE=${ANS:-$REMOTE}
REMOTE=${REMOTE%/}
BASE="ftp://$FTP_HOST/${REMOTE:+$REMOTE/}"

put() {
  if ftpc --ftp-create-dirs -T "$1" "$BASE$2" 2> "$TMP/err.txt"; then
    ok "$2"
  else
    bad "$2: $(tr '\n' ' ' < "$TMP/err.txt")"
    FAILED=1
  fi
}

# ---------- файлы сайта ----------
bold "Загрузка файлов в /${REMOTE}"
FAILED=0
for f in $FILES; do put "$f" "$f"; done

# Редирект на HTTPS включаем только при рабочем сертификате,
# иначе сайт откроется с ошибкой безопасности.
if curl -sS -o /dev/null -m 15 "https://$DOMAIN/robots.txt" 2>/dev/null; then
  put .htaccess .htaccess
  HTTPS_READY=1
else
  sed '/# BEGIN HTTPS/,/# END HTTPS/d' .htaccess > "$TMP/.htaccess"
  put "$TMP/.htaccess" .htaccess
  warn "сертификат для $DOMAIN пока не отвечает — редирект на HTTPS не включён"
  warn "запустите скрипт ещё раз, когда в панели сертификат станет «Активен»"
  HTTPS_READY=0
fi

# ---------- приём заявок ----------
bold "Приём заявок в Telegram"
read -r -p "Записать настройки бота на сервер? [Y/n]: " ANS
case "$ANS" in
  n*|N*|н*|Н*) warn "пропускаю — на сервере остаются прежние настройки" ;;
  *)
    read -r -s -p "Токен бота от @BotFather (ввод не отображается): " TG_TOKEN; echo
    read -r -p "Ваш chat_id от @userinfobot: " TG_CHAT
    TG_CHAT=$(printf '%s' "$TG_CHAT" | tr -d '[:space:]')

    if ! printf '%s' "$TG_TOKEN" | grep -Eq '^[0-9]+:[A-Za-z0-9_-]+$'; then
      bad "токен не похож на токен бота (формат 123456:ABC...)"; exit 1
    fi
    if ! printf '%s' "$TG_CHAT" | grep -Eq '^-?[0-9]+$'; then
      bad "chat_id должен состоять из цифр"; exit 1
    fi

    read -r -p "Дублировать заявки на почту (Enter — не нужно): " MAIL_TO
    MAIL_TO=$(printf '%s' "$MAIL_TO" | tr -d '[:space:]')
    if [ -n "$MAIL_TO" ] && ! printf '%s' "$MAIL_TO" | grep -Eq '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'; then
      bad "адрес почты указан с ошибкой"; exit 1
    fi
    MAIL_FROM=""
    [ -n "$MAIL_TO" ] && MAIL_FROM="info@$DOMAIN"

    # Токен уходит в curl через stdin, а не аргументом командной строки.
    curl -sS -m 15 -K - > "$TMP/tg.json" 2> "$TMP/err.txt" <<EOF
url = "https://api.telegram.org/bot$TG_TOKEN/sendMessage"
data-urlencode = "chat_id=$TG_CHAT"
data-urlencode = "text=✅ Бот подключён к сайту $DOMAIN. Сюда будут приходить заявки."
EOF
    if grep -q '"ok":true' "$TMP/tg.json"; then
      ok "тестовое сообщение пришло в Telegram"
    else
      bad "Telegram не принял сообщение:"
      sed 's/^/    /' "$TMP/tg.json" "$TMP/err.txt"
      echo "    Проверьте токен и что вы нажали «Start» в чате со своим ботом."
      exit 1
    fi

    umask 077
    cat > "$TMP/config.local.php" <<EOF
<?php
return [
    'tg_token'  => '$TG_TOKEN',
    'tg_chat'   => '$TG_CHAT',
    'mail_to'   => '$MAIL_TO',
    'mail_from' => '$MAIL_FROM',
    'min_seconds_between' => 20,
];
EOF
    unset TG_TOKEN
    put "$TMP/config.local.php" config.local.php
    ;;
esac

# ---------- проверка ----------
bold "Проверка сайта"
if [ "$HTTPS_READY" = 1 ]; then SCHEME=https; else SCHEME=http; fi
URL="$SCHEME://$DOMAIN"

code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "$URL/" 2>/dev/null)
if [ "$code" = 200 ]; then
  ok "$URL открывается"

  for p in privacy.html tariffs.html dogovor.html; do
    c=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "$URL/$p")
    [ "$c" = 200 ] && ok "$p" || bad "$p отвечает $c"
  done

  if curl -s -m 15 "$URL/config.local.php" | grep -q 'tg_token\|api\.telegram'; then
    bad "config.local.php читается снаружи — не запускайте рекламу, сообщите мне"
  else
    ok "настройки бота снаружи не читаются"
  fi
  c=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "$URL/leads.csv")
  case "$c" in 403|404) ok "журнал заявок снаружи недоступен ($c)" ;; *) bad "leads.csv отвечает $c — сообщите мне" ;; esac

  if [ "$HTTPS_READY" = 1 ]; then
    r=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -m 15 "http://$DOMAIN/")
    case "$r" in 301*https*) ok "http → https перенаправляется" ;; *) warn "редирект на https не сработал: $r" ;; esac
  fi

  read -r -p "Отправить тестовую заявку через форму сайта? [Y/n]: " ANS
  case "$ANS" in
    n*|N*|н*|Н*) ;;
    *)
      res=$(curl -s -m 20 "$URL/send.php" \
        --data-urlencode "name=Тестовая заявка" \
        --data-urlencode "phone=+7 (900) 000-00-00" \
        --data-urlencode "car=Проверка после выкладки" \
        --data-urlencode "amount=300 000 — 700 000 ₽" \
        --data-urlencode "consent=1" \
        --data-urlencode "page=/deploy-check")
      case "$res" in
        *'"ok":true'*) ok "заявка принята — проверьте Telegram" ;;
        *) bad "обработчик ответил: $res" ;;
      esac
      ;;
  esac
else
  warn "$URL пока не открывается (код $code)"
  warn "если домен куплен меньше суток назад — DNS ещё обновляется, это нормально"
fi

bold "Готово"
[ "$FAILED" = 1 ] && bad "часть файлов не загрузилась — см. выше" || ok "все файлы на месте"
[ "$HTTPS_READY" = 0 ] && warn "после выпуска сертификата запустите: bash deploy.sh"
echo
