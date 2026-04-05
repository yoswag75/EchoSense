#include <WiFi.h>
#include <HTTPClient.h>
#include <WiFiClientSecure.h>
#include "driver/i2s.h"

// ==========================================
// WI-FI & SERVER CONFIGURATION
// ==========================================
const char* ssid = "[WiFi-ID]";
const char* password = "[WiFi-Password]";

// Your live Render server URL
const String serverName = "https://nlp-echosense-backend.onrender.com/audio"; 

// ==========================================
// HARDWARE & AUDIO CONFIGURATION
// ==========================================
// I2S microphone pins (INMP441)
#define I2S_WS 25
#define I2S_SD 33
#define I2S_SCK 26

#define SAMPLE_RATE 16000
#define READ_LEN 512
#define CLIP_SIZE 16000   // 16000 samples = 1 second of audio

#define VAD_THRESHOLD 800 // Volume threshold to trigger recording

// Buffers
int32_t i2s_buffer[READ_LEN];
int16_t audio_buffer[READ_LEN];
int16_t clip_buffer[CLIP_SIZE];
uint8_t compressed_buffer[CLIP_SIZE];

// ==========================================
// AUDIO PROCESSING FUNCTIONS
// ==========================================

// μ-law compression (reduces 16-bit audio to 8-bit for faster Wi-Fi upload)
uint8_t mulaw_encode(int16_t sample) {
  const uint16_t MULAW_MAX = 0x1FFF;
  const uint16_t MULAW_BIAS = 33;

  uint8_t sign = (sample >> 8) & 0x80;
  if (sign != 0) sample = -sample;
  if (sample > MULAW_MAX) sample = MULAW_MAX;
  sample += MULAW_BIAS;

  uint8_t exponent = 7;
  for (uint16_t expMask = 0x4000; (sample & expMask) == 0 && exponent > 0; exponent--) {
    expMask >>= 1;
  }

  uint8_t mantissa = (sample >> (exponent + 3)) & 0x0F;
  uint8_t mu = ~(sign | (exponent << 4) | mantissa);

  return mu;
}

// Setup I2S Microphone
void setup_i2s() {
  i2s_config_t i2s_config = {
    .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
    .sample_rate = SAMPLE_RATE,
    .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
    .channel_format = I2S_CHANNEL_FMT_ONLY_LEFT,
    .communication_format = I2S_COMM_FORMAT_I2S,
    .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
    .dma_buf_count = 8,
    .dma_buf_len = READ_LEN
  };

  i2s_pin_config_t pin_config = {
    .bck_io_num = I2S_SCK,
    .ws_io_num = I2S_WS,
    .data_out_num = -1,
    .data_in_num = I2S_SD
  };

  i2s_driver_install(I2S_NUM_0, &i2s_config, 0, NULL);
  i2s_set_pin(I2S_NUM_0, &pin_config);
}

// Energy-based Voice/Sound Activity Detection (VAD)
bool detect_sound(int16_t *buffer, int samples) {
  long energy = 0;
  for(int i = 0; i < samples; i++) {
    energy += abs(buffer[i]);
  }
  energy = energy / samples;
  
  return (energy > VAD_THRESHOLD);
}

// Record the remainder of the 1-second clip
// (starting_index allows us to keep the frame that triggered the sound)
void record_audio(int starting_index) {
  size_t bytes_read;
  int index = starting_index;

  while(index < CLIP_SIZE) {
    i2s_read(I2S_NUM_0, i2s_buffer, sizeof(i2s_buffer), &bytes_read, portMAX_DELAY);
    int samples = bytes_read / 4;

    for(int i = 0; i < samples; i++) {
      int16_t sample = i2s_buffer[i] >> 14;
      clip_buffer[index++] = sample;

      if(index >= CLIP_SIZE) break;
    }
  }
}

// Compress the full 1-second clip
void compress_audio() {
  for(int i = 0; i < CLIP_SIZE; i++) {
    compressed_buffer[i] = mulaw_encode(clip_buffer[i]);
  }
}

// ==========================================
// NETWORK FUNCTIONS
// ==========================================

// Send audio via HTTPS POST to FastAPI Server
void upload_audio() {
  if (WiFi.status() == WL_CONNECTED) {
    
    // Create a secure client and set it to insecure for easy prototyping
    WiFiClientSecure client;
    client.setInsecure(); 

    HTTPClient http;
    http.begin(client, serverName); 
    
    // Explicitly declare we are sending a raw byte stream
    http.addHeader("Content-Type", "application/octet-stream");

    Serial.println("Uploading 1s audio to Cloud ML Server...");
    
    // Send the compressed buffer via POST
    int httpResponseCode = http.POST(compressed_buffer, CLIP_SIZE);

    if (httpResponseCode > 0) {
      Serial.print("HTTP Response code: ");
      Serial.println(httpResponseCode); // Should be 200 OK
    } else {
      Serial.print("Error code: ");
      Serial.println(httpResponseCode); 
    }
    
    http.end();
  } else {
    Serial.println("WiFi Disconnected! Cannot upload audio.");
  }
}

// ==========================================
// MAIN ARDUINO LOOP
// ==========================================

void setup() {
  Serial.begin(115200); 
  delay(1000);

  // Connect to Wi-Fi
  WiFi.begin(ssid, password);
  Serial.print("Connecting to WiFi...");
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.println("\nWiFi Connected!");
  Serial.print("ESP32 IP Address: ");
  Serial.println(WiFi.localIP());

  setup_i2s();

  Serial.println("System Ready. Listening for audio events...");
}

void loop() {
  size_t bytes_read;

  // Continuously read a small chunk of audio
  i2s_read(I2S_NUM_0, i2s_buffer, sizeof(i2s_buffer), &bytes_read, portMAX_DELAY);
  int samples = bytes_read / 4;

  for(int i = 0; i < samples; i++) {
    audio_buffer[i] = i2s_buffer[i] >> 14;
  }

  // Check if the chunk breaches the volume threshold
  if(detect_sound(audio_buffer, samples)) {
    Serial.println("\n--- Sound Detected! ---");

    // 1. Save the triggering audio frame so we don't lose the start of the sound
    for(int i = 0; i < samples; i++) {
      clip_buffer[i] = audio_buffer[i];
    }

    // 2. Record the rest of the 1-second clip (starting after the initial samples)
    record_audio(samples);

    // 3. Compress the audio to u-law
    compress_audio();

    // 4. Upload to Render backend
    upload_audio();

    // 5. Cooldown to prevent spamming the server
    Serial.println("Cooldown active (2 seconds)...");
    delay(2000);   
    Serial.println("Listening again...");
  }
}
