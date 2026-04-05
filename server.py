import numpy as np
import librosa
import tensorflow as tf
from fastapi import FastAPI, Request, WebSocket, WebSocketDisconnect
import uvicorn
import audioop
import pickle
from tensorflow.keras.models import load_model
import os

app = FastAPI()

# --- LOAD MODEL & CLASSES ---
print("Loading ML Model & Classes...")

try:
    BASE_DIR = os.path.dirname(__file__)

    # Load Keras model
    model = load_model(os.path.join(BASE_DIR, "model.h5"))

    # Load class labels (assumed stored in .pkl)
    with open(os.path.join(BASE_DIR, "model.pkl"), "rb") as f:
        CLASSES = pickle.load(f)

    print("Model loaded successfully")

except Exception as e:
    print(f"Error loading model/classes: {e}")
    model = None
    CLASSES = None


# --- WEBSOCKET CONNECTION MANAGER ---
class ConnectionManager:
    def __init__(self):
        self.active_connections: list[WebSocket] = []

    async def connect(self, websocket: WebSocket):
        await websocket.accept()
        self.active_connections.append(websocket)
        print("Mobile App connected via WebSocket!")

    def disconnect(self, websocket: WebSocket):
        if websocket in self.active_connections:
            self.active_connections.remove(websocket)
        print("Mobile App disconnected.")

    async def broadcast(self, message: dict):
        for connection in self.active_connections:
            try:
                await connection.send_json(message)
            except:
                pass


manager = ConnectionManager()


# --- WEBSOCKET ROUTE (For Flutter App) ---
@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await manager.connect(websocket)
    try:
        while True:
            await websocket.receive_text()  # keep alive
    except WebSocketDisconnect:
        manager.disconnect(websocket)


# --- HTTP POST ROUTE (For ESP32) ---
@app.post("/audio")
async def receive_audio(request: Request):
    ulaw_bytes = await request.body()

    if not ulaw_bytes:
        return {"error": "Empty payload"}

    print(f"Received {len(ulaw_bytes)} bytes of audio from ESP32.")

    await manager.broadcast({
        "event": "hardware_status",
        "data": {"state": "ANALYZING", "msg": "Running Cloud ML Model..."}
    })

    if not model or not CLASSES:
        return {"error": "Model not loaded on server."}

    try:
        # --- 1. Decode ESP32 u-law to PCM ---
        pcm_data = audioop.ulaw2lin(ulaw_bytes, 2)
        audio_np = np.frombuffer(pcm_data, dtype=np.int16).astype(np.float32) / 32768.0

        # --- 2. Volume (dB) ---
        rms = np.sqrt(np.mean(audio_np ** 2))
        db = int(20 * np.log10(rms)) if rms > 0 else -100
        normalized_db = max(0, min(100, db + 100))

        # --- 3. Mel Spectrogram ---
        mel = librosa.feature.melspectrogram(y=audio_np, sr=16000)
        mel_db = librosa.power_to_db(mel)

        # Resize to (128, 128)
        if mel_db.shape[1] < 128:
            pad_width = 128 - mel_db.shape[1]
            mel_db = np.pad(mel_db, ((0, 0), (0, pad_width)), mode='constant')
        else:
            mel_db = mel_db[:, :128]

        mel_db = mel_db[:128, :]
        mel_db = mel_db.reshape(1, 128, 128, 1)

        # --- 4. Prediction ---
        predictions = model.predict(mel_db, verbose=0)[0]
        class_idx = np.argmax(predictions)
        confidence = int(predictions[class_idx] * 100)

        predicted_class = CLASSES[class_idx]

        print(f"--> Predicted: {predicted_class} ({confidence}%) at {normalized_db}dB")

        # --- 5. Send to Flutter ---
        await manager.broadcast({
            "event": "sound_event",
            "data": {
                "category": predicted_class,
                "confidence": confidence,
                "db": normalized_db
            }
        })

        await manager.broadcast({
            "event": "hardware_status",
            "data": {"state": "IDLE", "msg": "Listening to Environment..."}
        })

        return {"status": "success", "prediction": predicted_class}

    except Exception as e:
        print(f"Error processing audio data: {e}")
        return {"error": str(e)}


# --- RUN SERVER ---
if __name__ == '__main__':
    print("Starting FastAPI Cloud Server...")
    uvicorn.run(app, host='0.0.0.0', port=8000)
