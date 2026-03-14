import numpy as np
import tensorflow as tf
from sklearn.preprocessing import LabelEncoder
from sklearn.model_selection import train_test_split
from tensorflow.keras.utils import to_categorical
from tensorflow.keras import layers, models
import joblib

from preprocess_dataset import load_dataset

# Load dataset
dataset_path = "sound_threat_detection/dataset"
X, y = load_dataset(dataset_path)

print("Dataset loaded")
print("X shape:", X.shape)
print("y shape:", y.shape)

# Encode labels
label_encoder = LabelEncoder()
y_encoded = label_encoder.fit_transform(y)
y_categorical = to_categorical(y_encoded)

# Save the label encoder classes so the server knows the exact mapping
joblib.dump(label_encoder.classes_, 'classes.pkl')

# Split dataset
X_train, X_test, y_train, y_test = train_test_split(
    X, y_categorical, test_size=0.2, random_state=42
)

# CNN Model
num_classes = y_categorical.shape[1]

model = models.Sequential()
model.add(layers.Conv2D(16, (3,3), activation='relu', input_shape=(128,128,1)))
model.add(layers.MaxPooling2D((2,2)))

model.add(layers.Conv2D(32, (3,3), activation='relu'))
model.add(layers.MaxPooling2D((2,2)))

model.add(layers.Flatten())
model.add(layers.Dense(64, activation='relu'))
model.add(layers.Dense(num_classes, activation='softmax'))

# Compile & Train
model.compile(optimizer='adam', loss='categorical_crossentropy', metrics=['accuracy'])
model.fit(X_train, y_train, epochs=20, batch_size=32, validation_data=(X_test, y_test))

# Save model
model.save("sound_model.h5")
print("Model saved to sound_model.h5")

# Convert to TensorFlow Lite
converter = tf.lite.TFLiteConverter.from_keras_model(model)
tflite_model = converter.convert()

with open("sound_model.tflite", "wb") as f:
    f.write(tflite_model)
print("Model converted to TensorFlow Lite (sound_model.tflite)")