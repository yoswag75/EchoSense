#include "driver/i2s.h"

// I2S microphone pins
#define I2S_WS 25
#define I2S_SD 33
#define I2S_SCK 26

#define SAMPLE_RATE 16000
#define READ_LEN 512
#define CLIP_SIZE 16000

#define VAD_THRESHOLD 800

int32_t i2s_buffer[READ_LEN];
int16_t audio_buffer[READ_LEN];

int16_t clip_buffer[CLIP_SIZE];
uint8_t compressed_buffer[CLIP_SIZE];


// μ-law compression
uint8_t mulaw_encode(int16_t sample)
{
  const uint16_t MULAW_MAX = 0x1FFF;
  const uint16_t MULAW_BIAS = 33;

  uint8_t sign = (sample >> 8) & 0x80;

  if (sign != 0)
    sample = -sample;

  if (sample > MULAW_MAX)
    sample = MULAW_MAX;

  sample += MULAW_BIAS;

  uint8_t exponent = 7;

  for (uint16_t expMask = 0x4000;
       (sample & expMask) == 0 && exponent > 0;
       exponent--)
    expMask >>= 1;

  uint8_t mantissa = (sample >> (exponent + 3)) & 0x0F;

  uint8_t mu = ~(sign | (exponent << 4) | mantissa);

  return mu;
}


// Setup microphone
void setup_i2s()
{
  i2s_config_t i2s_config =
  {
    .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
    .sample_rate = SAMPLE_RATE,
    .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
    .channel_format = I2S_CHANNEL_FMT_ONLY_LEFT,
    .communication_format = I2S_COMM_FORMAT_I2S,
    .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
    .dma_buf_count = 8,
    .dma_buf_len = READ_LEN
  };

  i2s_pin_config_t pin_config =
  {
    .bck_io_num = I2S_SCK,
    .ws_io_num = I2S_WS,
    .data_out_num = -1,
    .data_in_num = I2S_SD
  };

  i2s_driver_install(I2S_NUM_0, &i2s_config, 0, NULL);
  i2s_set_pin(I2S_NUM_0, &pin_config);
}


// Energy-based VAD
bool detect_sound(int16_t *buffer, int samples)
{
  long energy = 0;

  for(int i = 0; i < samples; i++)
  {
    energy += abs(buffer[i]);
  }

  energy = energy / samples;

  if(energy > VAD_THRESHOLD)
    return true;

  return false;
}


// Record 1 second audio
void record_audio()
{
  size_t bytes_read;
  int index = 0;

  while(index < CLIP_SIZE)
  {
    i2s_read(I2S_NUM_0,
             i2s_buffer,
             sizeof(i2s_buffer),
             &bytes_read,
             portMAX_DELAY);

    int samples = bytes_read / 4;

    for(int i=0;i<samples;i++)
    {
      int16_t sample = i2s_buffer[i] >> 14;

      clip_buffer[index++] = sample;

      if(index >= CLIP_SIZE)
        break;
    }
  }
}


// Compress audio
void compress_audio()
{
  for(int i=0;i<CLIP_SIZE;i++)
  {
    compressed_buffer[i] = mulaw_encode(clip_buffer[i]);
  }
}


// Send audio
void send_audio()
{
  Serial.println("START_AUDIO");

  for(int i = 0; i < CLIP_SIZE; i += 256)
  {
    Serial.write(&compressed_buffer[i], 256);
    delay(2);   // allow serial buffer to flush
  }

  Serial.println();
  Serial.println("END_AUDIO");
}


void setup()
{
  Serial.begin(921600);

  delay(2000);

  setup_i2s();

  Serial.println("System Ready");
}


void loop()
{
  size_t bytes_read;

  i2s_read(I2S_NUM_0,
           i2s_buffer,
           sizeof(i2s_buffer),
           &bytes_read,
           portMAX_DELAY);

  int samples = bytes_read / 4;

  for(int i=0;i<samples;i++)
  {
    audio_buffer[i] = i2s_buffer[i] >> 14;
  }

  if(detect_sound(audio_buffer, samples))
  {
    Serial.println("Sound Detected");

    record_audio();

    compress_audio();

    send_audio();

    delay(2000);   // cooldown
  }
}