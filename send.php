<?php
/**
 * Обработчик заявок с лендинга.
 * Отправляет заявку в Telegram и дублирует на почту, пишет CSV-журнал.
 *
 * Настройки — в config.local.php (скопируйте из config.example.php).
 * Этот файл не попадает в git: токен бота даёт полный доступ к нему.
 */

ini_set('display_errors', '0');   // предупреждения PHP не должны ломать JSON-ответ форме

$configFile = __DIR__ . '/config.local.php';
$cfg = is_file($configFile) ? require $configFile : [];

$TG_TOKEN   = $cfg['tg_token']  ?? '';
$TG_CHAT    = $cfg['tg_chat']   ?? '';
$MAIL_TO    = $cfg['mail_to']   ?? '';
$MAIL_FROM  = $cfg['mail_from'] ?? '';
$MIN_SECONDS_BETWEEN = $cfg['min_seconds_between'] ?? 20;

// Журнал заявок — на уровень выше public_html, куда веб-сервер не отдаёт файлы.
// Если туда писать нельзя, остаётся рядом; там его закрывает .htaccess.
$logDir   = is_writable(dirname(__DIR__)) ? dirname(__DIR__) : __DIR__;
$LOG_FILE = $logDir . '/leads.csv';

date_default_timezone_set('Europe/Moscow');   // Казань живёт по московскому времени
header('Content-Type: application/json; charset=utf-8');

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    exit(json_encode(['ok' => false, 'error' => 'method']));
}

// Ловушка для ботов: поле скрыто от людей, заполняется только автоматикой.
if (!empty($_POST['company'])) {
    exit(json_encode(['ok' => true]));   // молча принимаем, но никуда не отправляем
}

// Простой лимит по частоте.
session_start();
$now = time();
if (isset($_SESSION['last_lead']) && $now - $_SESSION['last_lead'] < $MIN_SECONDS_BETWEEN) {
    http_response_code(429);
    exit(json_encode(['ok' => false, 'error' => 'too_fast']));
}

function clean($key, $limit = 200) {
    $v = isset($_POST[$key]) ? (string)$_POST[$key] : '';
    $v = strip_tags(trim($v));
    return mb_substr($v, 0, $limit);
}

$name  = clean('name', 80);
$phone = clean('phone', 30);
$car   = clean('car', 120);
$sum   = clean('amount', 60);
$cSum  = clean('calc_sum', 40);
$cTerm = clean('calc_term', 20);
$cCar  = clean('calc_car', 40);
$page  = clean('page', 200);

// Телефон обязателен и должен содержать не меньше 10 цифр.
$digits = preg_replace('/\D+/', '', $phone);
if (strlen($digits) < 10) {
    http_response_code(422);
    exit(json_encode(['ok' => false, 'error' => 'phone']));
}

// Без согласия на обработку ПДн заявку не принимаем, даже если форму обошли.
if (($_POST['consent'] ?? '') !== '1') {
    http_response_code(422);
    exit(json_encode(['ok' => false, 'error' => 'consent']));
}

$_SESSION['last_lead'] = $now;

$ip  = $_SERVER['HTTP_X_FORWARDED_FOR'] ?? $_SERVER['REMOTE_ADDR'] ?? '';
$utm = [];
foreach (['utm_source', 'utm_medium', 'utm_campaign', 'utm_term', 'utm_content'] as $k) {
    if (!empty($_POST[$k])) $utm[] = $k . '=' . clean($k, 60);
}

$lines = [
    "🚗 Новая заявка с сайта",
    "",
    "Имя: "      . ($name  !== '' ? $name  : '—'),
    "Телефон: "  . $phone,
    "Авто: "     . ($car   !== '' ? $car   : '—'),
    "Сумма: "    . ($sum   !== '' ? $sum   : '—'),
    "Калькулятор: {$cSum} на {$cTerm}, авто {$cCar}",
    "Страница: " . ($page !== '' ? $page : '/'),
];
if ($utm)  $lines[] = "Метки: " . implode(' · ', $utm);
$lines[] = "Время: " . date('d.m.Y H:i');
$text = implode("\n", $lines);

// ---- Telegram ----
$sent = false;
if ($TG_TOKEN && $TG_CHAT) {
    $ch = curl_init("https://api.telegram.org/bot{$TG_TOKEN}/sendMessage");
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 8,
        CURLOPT_POST           => true,
        CURLOPT_POSTFIELDS     => ['chat_id' => $TG_CHAT, 'text' => $text],
    ]);
    $sent = curl_exec($ch) !== false && curl_getinfo($ch, CURLINFO_HTTP_CODE) === 200;
}

// ---- Почта ----
if ($MAIL_TO && $MAIL_FROM) {
    $utf = function ($s) { return '=?UTF-8?B?' . base64_encode($s) . '?='; };
    $headers  = "From: " . $utf('Сайт') . " <{$MAIL_FROM}>\r\n";
    $headers .= "MIME-Version: 1.0\r\n";
    $headers .= "Content-Type: text/plain; charset=utf-8\r\n";
    if (@mail($MAIL_TO, $utf('Заявка с сайта: ' . $phone), $text, $headers)) $sent = true;
}

// ---- Журнал ----
// Excel исполняет ячейки, начинающиеся с = + - @, как формулы — экранируем.
$csvSafe = function ($v) {
    return preg_match('/^[=+\-@]/', (string)$v) ? "'" . $v : $v;
};
if ($fh = @fopen($LOG_FILE, 'a')) {
    $row = [date('Y-m-d H:i:s'), $name, $phone, $car, $sum, $cSum, $cTerm, $page, implode(' ', $utm), $ip];
    fputcsv($fh, array_map($csvSafe, $row), ',', '"', '');
    fclose($fh);
    $sent = true;
}

if (!$sent) {
    http_response_code(500);
    exit(json_encode(['ok' => false, 'error' => 'delivery']));
}

echo json_encode(['ok' => true]);
