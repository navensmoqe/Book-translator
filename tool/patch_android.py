from pathlib import Path
import sys

manifest = Path(sys.argv[1])
text = manifest.read_text(encoding="utf-8")

permission = '<uses-permission android:name="android.permission.INTERNET" />'
if permission not in text:
    idx = text.find(">")
    text = text[: idx + 1] + "\n    " + permission + text[idx + 1 :]

text = text.replace(
    'android:label="pdf_arabic_translator"',
    'android:label="PDF Arabic Translator"',
)
manifest.write_text(text, encoding="utf-8")

# Android app directory: android/app
app_dir = manifest.parents[2]

# google_mlkit_text_recognition references all script recognizers from its
# native Android implementation. Release R8 therefore needs these optional
# classes to be present even though this app currently creates the Latin
# recognizer only.
kts = app_dir / "build.gradle.kts"
groovy = app_dir / "build.gradle"

marker = "BOOK_TRANSLATOR_MLKIT_OPTIONAL_LANGUAGES"

if kts.exists():
    gradle = kts.read_text(encoding="utf-8")
    if marker not in gradle:
        gradle += f"""
// {marker}
dependencies {{
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
    implementation("com.google.mlkit:text-recognition-devanagari:16.0.1")
    implementation("com.google.mlkit:text-recognition-japanese:16.0.1")
    implementation("com.google.mlkit:text-recognition-korean:16.0.1")
}}
"""
        kts.write_text(gradle, encoding="utf-8")
elif groovy.exists():
    gradle = groovy.read_text(encoding="utf-8")
    if marker not in gradle:
        gradle += f"""
// {marker}
dependencies {{
    implementation 'com.google.mlkit:text-recognition-chinese:16.0.1'
    implementation 'com.google.mlkit:text-recognition-devanagari:16.0.1'
    implementation 'com.google.mlkit:text-recognition-japanese:16.0.1'
    implementation 'com.google.mlkit:text-recognition-korean:16.0.1'
}}
"""
        groovy.write_text(gradle, encoding="utf-8")
else:
    raise SystemExit("Could not find android/app/build.gradle(.kts)")

# Fallback R8 rules. The four dependencies above provide the classes; these
# rules also make future optional-script changes less likely to stop release
# builds when only the Latin recognizer is used.
proguard = app_dir / "proguard-rules.pro"
rules = """
# Book Translator / ML Kit optional text-recognition scripts
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
"""
existing = proguard.read_text(encoding="utf-8") if proguard.exists() else ""
if "Book Translator / ML Kit optional" not in existing:
    proguard.write_text(existing + "\n" + rules, encoding="utf-8")
