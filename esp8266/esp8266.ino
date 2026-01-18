#include <ESP8266WiFi.h>
#include <ESP8266HTTPClient.h>
#include <WiFiClient.h>
#include <WiFiClientSecure.h>
#include "config.h"

#if DEBUG_SERIAL
  #define LOG_BEGIN() Serial.begin(115200)
  #define LOGF(...) Serial.printf(__VA_ARGS__)
#else
  #define LOG_BEGIN()
  #define LOGF(...)
#endif

#define HEARTBEAT_MIN 10000
#define WIFI_TIMEOUT_MIN 10000
#define MAX_FAILS 10
#define DAILY_RESTART_MS (24UL * 60 * 60 * 1000)
#define MIN_HEAP 8000
#define MIN_LARGEST_BLOCK 4000
#define HTTP_RETRY_COUNT 3
#define HTTP_RETRY_DELAY 2000
#define WIFI_RECONNECT_DELAY 5000

unsigned long lastHB = 0;
unsigned long lastWifiCheck = 0;
int fails = 0;
int wifiReconnects = 0;
int tokenErrors = 0;
bool useHttps = false;
bool stopped = false;

void setup() {
    LOG_BEGIN();
    pinMode(LED_BUILTIN, OUTPUT);
    ledOff();
    
    if (strlen(DEVICE_TOKEN) < 10 || strlen(SERVER_URL) < 10) {
        for (int i = 0; i < 60; i++) {
            ledOn(); delay(500); ledOff(); delay(500);
            ESP.wdtFeed();
        }
        ESP.restart();
    }
    
    useHttps = strncmp(SERVER_URL, "https://", 8) == 0;
    WiFi.mode(WIFI_STA);
    WiFi.setAutoReconnect(true);
    WiFi.persistent(false);
    ESP.wdtEnable(WDTO_8S);
    
    connectWiFi();
    WiFi.setSleepMode(WIFI_NONE_SLEEP);
    
    for (int i = 0; i < 3 && !doHeartbeat(); i++) {
        delay(3000);
        ESP.wdtFeed();
    }
}

void loop() {
    ESP.wdtFeed();
    
    if (millis() > DAILY_RESTART_MS) ESP.restart();
    if (ESP.getFreeHeap() < MIN_HEAP) ESP.restart();
    if (ESP.getMaxFreeBlockSize() < MIN_LARGEST_BLOCK && ESP.getFreeHeap() > MIN_HEAP * 2) ESP.restart();
    
    if (stopped) {
        for (int i = 0; i < 60; i++) {
            ESP.wdtFeed();
            ledToggle();
            delay(5000);
        }
        stopped = false;
        tokenErrors = 0;
        ledOff();
        return;
    }
    
    if (millis() - lastWifiCheck > 30000) {
        lastWifiCheck = millis();
        if (WiFi.status() != WL_CONNECTED) {
            wifiReconnects++;
            connectWiFi();
            WiFi.setSleepMode(WIFI_NONE_SLEEP);
        }
        if (wifiReconnects > 10) ESP.restart();
    }
    
    if (WiFi.status() != WL_CONNECTED) {
        delay(WIFI_RECONNECT_DELAY);
        if (WiFi.status() != WL_CONNECTED) {
            connectWiFi();
            WiFi.setSleepMode(WIFI_NONE_SLEEP);
        }
    }
    
    unsigned long interval = max(HEARTBEAT_INTERVAL, (unsigned long)HEARTBEAT_MIN);
    if (millis() - lastHB >= interval) {
        if (doHeartbeat()) {
            fails = 0;
            wifiReconnects = 0;
            lastHB = millis();
        } else {
            fails++;
            if (fails >= MAX_FAILS) ESP.restart();
        }
    }
    
    delay(100);
}

void connectWiFi() {
    WiFi.disconnect(true);
    delay(100);
    delay(random(100, 2000));
    WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
    
    unsigned long start = millis();
    unsigned long timeout = max(WIFI_TIMEOUT, (unsigned long)WIFI_TIMEOUT_MIN);
    
    while (WiFi.status() != WL_CONNECTED) {
        ESP.wdtFeed();
        ledToggle();
        delay(300);
        if (millis() - start > timeout) ESP.restart();
    }
    ledOff();
    LOGF("WiFi OK %s RSSI:%d\n", WiFi.localIP().toString().c_str(), WiFi.RSSI());
}

bool doHeartbeat() {
    if (WiFi.status() != WL_CONNECTED) return false;
    if (WiFi.localIP() == IPAddress(0, 0, 0, 0)) return false;
    
    for (int attempt = 1; attempt <= HTTP_RETRY_COUNT; attempt++) {
        ESP.wdtFeed();
        if (attempt > 1) delay(HTTP_RETRY_DELAY);
        if (sendHeartbeat()) return true;
    }
    return false;
}

bool sendHeartbeat() {
    HTTPClient http;
    String url = String(SERVER_URL) + "/api/heartbeat";
    
    WiFiClient client;
    WiFiClientSecure secureClient;
    
    bool ok;
    if (useHttps) {
        secureClient.setInsecure();
        secureClient.setTimeout(15000);
        ok = http.begin(secureClient, url);
    } else {
        client.setTimeout(15000);
        ok = http.begin(client, url);
    }
    
    if (!ok) return false;
    
    http.addHeader("Content-Type", "application/json");
    http.addHeader("X-Device-Token", DEVICE_TOKEN);
    http.addHeader("Connection", "close");
    http.setTimeout(15000);
    http.setReuse(false);
    
    String json = "{\"rssi\":" + String(WiFi.RSSI()) + 
                  ",\"uptime\":" + String(millis()/1000) + 
                  ",\"heap\":" + String(ESP.getFreeHeap()) + "}";
    
    int code = http.POST(json);
    http.end();
    
    if (useHttps) secureClient.stop();
    else client.stop();
    
    if (code == 200) {
        LOGF("OK %d dBm\n", WiFi.RSSI());
        ledBlink();
        return true;
    }
    
    LOGF("HTTP %d\n", code);
    
    if (code == 401 || code == 409) {
        tokenErrors++;
        if (tokenErrors >= 5) {
            stopped = true;
            ledOn();
        }
        return false;
    }
    
    tokenErrors = 0;
    if (code == 429) delay(60000);
    
    return false;
}

void ledOn() { digitalWrite(LED_BUILTIN, LOW); }
void ledOff() { digitalWrite(LED_BUILTIN, HIGH); }
void ledToggle() { digitalWrite(LED_BUILTIN, !digitalRead(LED_BUILTIN)); }
void ledBlink() { ledOn(); delay(50); ledOff(); }
