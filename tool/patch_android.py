from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding='utf-8')
permission = '<uses-permission android:name="android.permission.INTERNET" />'
if permission not in text:
    idx = text.find('>')
    text = text[:idx+1] + '\n    ' + permission + text[idx+1:]
text = text.replace('android:label="pdf_arabic_translator"', 'android:label="PDF Arabic Translator"')
path.write_text(text, encoding='utf-8')
