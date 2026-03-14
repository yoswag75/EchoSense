import numpy as np
import librosa
import tensorflow as tf
from flask import Flask, request
from flask_socketio import SocketIO
import audioop
import joblib

app = Flask(__name__)
socketio = SocketIO(app, cors_allowed_origins="*")

# --- ML CONFIGURATION ---
MODEL_PATH = "sound_model.h5"
CLASSES_PATH = "classes.pkl"

print("Loading ML Model & Classes...")
try:
    model = tf.keras.models.load_model(MODEL_PATH)
    CLASSES = joblib.load(CLASSES_PATH)
    print(f"Model loaded successfully. Tracked Classes: {CLASSES}")
except Exception as e:
    print(f"Error loading model/classes (Ensure sound_model.h5 and classes.pkl exist): {e}")
    model = None

def process_audio_and_predict(ulaw_bytes):
    if not model:
        print("Model not loaded. Skipping prediction.")
        return
    
    try:
        # 1. Decode ESP32 u-law to 16-bit PCM and map to float32
        pcm_data = audioop.ulaw2lin(ulaw_bytes, 2)
        audio_np = np.frombuffer(pcm_data, dtype=np.int16).astype(np.float32) / 32768.0
        
        # Calculate approximate volume (dB) for the UI
        rms = np.sqrt(np.mean(audio_np**2))
        db = int(20 * np.log10(rms)) if rms > 0 else -100
        normalized_db = max(0, min(100, db + 100))
        
        # 2. Extract Mel Spectrogram (Must match preprocess_dataset.py logic)
        mel = librosa.feature.melspectrogram(y=audio_np, sr=16000)
        mel_db = librosa.power_to_db(mel)
        
        if mel_db.shape[1] < 128:
            pad_width = 128 - mel_db.shape[1]
            mel_db = np.pad(mel_db, pad_width=((0,0), (0, pad_width)), mode='constant')
        else:
            mel_db = mel_db[:128, :128]
            
        mel_db = mel_db.reshape(1, 128, 128, 1)
        
        # 3. Model Prediction
        socketio.emit('hardware_status', {'state': 'ANALYZING', 'msg': 'Running ML Model...'})
        
        predictions = model.predict(mel_db, verbose=0)[0]
        class_idx = np.argmax(predictions)
        confidence = int(predictions[class_idx] * 100)
        predicted_class = CLASSES[class_idx]
        
        print(f"--> Predicted: {predicted_class} ({confidence}%) at {normalized_db}dB")
        
        # 4. Push real data to Flutter
        socketio.emit('sound_event', {
            'category': predicted_class,
            'confidence': confidence,
            'db': normalized_db
        })
        
        socketio.emit('hardware_status', {'state': 'IDLE', 'msg': 'Listening (Network)...'})
        
    except Exception as e:
        print(f"Error processing audio data: {e}")

# This route receives the POST request from the ESP32
@app.route('/audio', methods=['POST'])
def receive_audio():
    ulaw_bytes = request.data
    if ulaw_bytes:
        socketio.emit('hardware_status', {'state': 'TRIGGERED', 'msg': 'Received Audio from ESP32!'})
        print(f"Received {len(ulaw_bytes)} bytes of audio from ESP32.")
        process_audio_and_predict(ulaw_bytes)
        return "Audio processed", 200
    else:
        return "Empty payload", 400

@socketio.on('connect')
def handle_connect():
    print("Mobile App Connected via WebSocket!")
    socketio.emit('hardware_status', {'state': 'IDLE', 'msg': 'Connected to Edge Server'})

if __name__ == '__main__':
    print("Starting Edge Server (Wi-Fi Receiver Mode).")
    print("Make sure the ESP32 is pointed to this PC's IP address on port 5000.")
    socketio.run(app, host='0.0.0.0', port=5000, allow_unsafe_werkzeug=True)