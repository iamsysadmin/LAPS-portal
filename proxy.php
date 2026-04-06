<?php
error_reporting(E_ALL);
$functionUrl = getenv('FUNCTION_URL');

if (!$functionUrl) {
    http_response_code(500);
    header('Content-Type: application/json');
    echo json_encode(['error' => 'FUNCTION_URL environment variable not set']);
    exit;
}
$deviceName  = $_GET['deviceName'] ?? '';
$callerUpn   = $_GET['callerUpn'] ?? '';

if (!$deviceName) {
    http_response_code(400);
    header('Content-Type: application/json');
    echo json_encode(['error' => 'deviceName is required']);
    exit;
}

$url = $functionUrl . '&deviceName=' . urlencode($deviceName) . '&callerUpn=' . urlencode($callerUpn);

$ch = curl_init($url);
curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
curl_setopt($ch, CURLOPT_TIMEOUT, 30);
$response = curl_exec($ch);
$httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
curl_close($ch);

http_response_code($httpCode);
header('Content-Type: application/json');
echo $response;
