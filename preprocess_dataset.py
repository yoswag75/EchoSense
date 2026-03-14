import os
import numpy as np
import librosa
import audioop

# Function to convert audio file to spectrogram (Supports .wav and .ulaw)
def extract_features(file_path):
    sr = 16000
    
    if file_path.endswith(".wav"):
        # Load standard WAV audio (limit to 3 seconds)
        audio, sr = librosa.load(file_path, sr=sr, duration=3)
        
    elif file_path.endswith(".ulaw"):
        # Load raw u-law bytes directly
        with open(file_path, "rb") as f:
            ulaw_bytes = f.read()
            
        # Decode u-law to 16-bit PCM, then convert to float32
        pcm_data = audioop.ulaw2lin(ulaw_bytes, 2)
        audio = np.frombuffer(pcm_data, dtype=np.int16).astype(np.float32) / 32768.0
        
        # Limit to 3 seconds (48,000 samples at 16kHz)
        if len(audio) > sr * 3:
            audio = audio[:sr * 3]
    else:
        raise ValueError("Unsupported audio format")

    # Generate Mel Spectrogram
    mel = librosa.feature.melspectrogram(y=audio, sr=sr)

    # Convert to decibel scale
    mel_db = librosa.power_to_db(mel)

    # Standardize size to exactly 128x128
    if mel_db.shape[1] < 128:
        pad_width = 128 - mel_db.shape[1]
        mel_db = np.pad(mel_db, pad_width=((0,0), (0, pad_width)), mode='constant')
    else:
        mel_db = mel_db[:128, :128]

    # Add channel dimension for CNN (128, 128, 1)
    mel_db = mel_db.reshape(128, 128, 1)

    return mel_db


# Function to load entire dataset
def load_dataset(dataset_path):
    X = []
    y = []

    # Get class folders
    classes = os.listdir(dataset_path)

    for label in classes:
        folder_path = os.path.join(dataset_path, label)

        if not os.path.isdir(folder_path):
            continue

        for file in os.listdir(folder_path):
            # Accept BOTH file formats
            if file.endswith(".wav") or file.endswith(".ulaw"):
                file_path = os.path.join(folder_path, file)
                try:
                    features = extract_features(file_path)
                    X.append(features)
                    y.append(label)
                except Exception as e:
                    print(f"Error processing {file_path}: {e}")

    X = np.array(X)
    y = np.array(y)

    return X, y

if __name__ == "__main__":
    dataset_path = "sound_threat_detection/dataset"
    print("Loading dataset...")
    X, y = load_dataset(dataset_path)
    print("Dataset loaded successfully!")
    print("Feature shape:", X.shape)
    print("Labels shape:", y.shape)