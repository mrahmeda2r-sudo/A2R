"""يولّد أيقونة التطبيق وشاشة الفتح من logo_fg.png و logo_splash.png
ويحطهم في android/app/src/main/res. بيتشغل من ملف البناء (GitHub Actions)."""
import os
from PIL import Image, ImageDraw

BG = (14, 19, 26)  # #0E131A
BG_HEX = '#0E131A'
RES = 'android/app/src/main/res'


def put(path, data, mode='w'):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, mode, encoding=None if 'b' in mode else 'utf-8') as f:
        f.write(data)


fg = Image.open('logo_fg.png').convert('RGBA')      # 1024x1024 شفافة، الحروف جوه المنطقة الآمنة
splash = Image.open('logo_splash.png').convert('RGBA')

# أيقونة قديمة (أندرويد 7 وأقل): مربع غامق بحواف مدوّرة. بناخد النص الأوسط 72/108 من الـ foreground.
legacy = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}
# foreground للأيقونة المتكيّفة (أندرويد 8+): 108dp
adaptive = {'mdpi': 108, 'hdpi': 162, 'xhdpi': 216, 'xxhdpi': 324, 'xxxhdpi': 432}

c0 = int(1024 * (1 - 72 / 108) / 2)
center = fg.crop((c0, c0, 1024 - c0, 1024 - c0))
for d, px in legacy.items():
    S = px * 4
    base = Image.new('RGBA', (S, S), BG + (255,))
    base.alpha_composite(center.resize((S, S), Image.LANCZOS))
    mask = Image.new('L', (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, S - 1, S - 1), radius=int(S * 0.2), fill=255)
    base.putalpha(mask)
    out = base.resize((px, px), Image.LANCZOS)
    p = f'{RES}/mipmap-{d}/ic_launcher.png'
    os.makedirs(os.path.dirname(p), exist_ok=True)
    out.save(p)
for d, px in adaptive.items():
    p = f'{RES}/mipmap-{d}/ic_launcher_foreground.png'
    os.makedirs(os.path.dirname(p), exist_ok=True)
    fg.resize((px, px), Image.LANCZOS).save(p)

put(f'{RES}/values/ic_launcher_background.xml',
    f'<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <color name="ic_launcher_background">{BG_HEX}</color>\n</resources>\n')
put(f'{RES}/mipmap-anydpi-v26/ic_launcher.xml',
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
    '    <background android:drawable="@color/ic_launcher_background"/>\n'
    '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
    '</adaptive-icon>\n')

# شاشة الفتح: خلفية غامقة + الشعار في النص
os.makedirs(f'{RES}/drawable-nodpi', exist_ok=True)
splash.save(f'{RES}/drawable-nodpi/splash_logo.png')
launch = ('<?xml version="1.0" encoding="utf-8"?>\n'
          '<layer-list xmlns:android="http://schemas.android.com/apk/res/android">\n'
          '    <item android:drawable="@color/ic_launcher_background"/>\n'
          '    <item>\n'
          '        <bitmap android:gravity="center" android:src="@drawable/splash_logo"/>\n'
          '    </item>\n'
          '</layer-list>\n')
put(f'{RES}/drawable/launch_background.xml', launch)
put(f'{RES}/drawable-v21/launch_background.xml', launch)

# أندرويد 12+ بيعمل شاشة فتح بنفسه من الأيقونة
v31 = ('<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
       '    <style name="LaunchTheme" parent="@android:style/Theme.Light.NoTitleBar">\n'
       '        <item name="android:windowBackground">@drawable/launch_background</item>\n'
       '        <item name="android:windowSplashScreenBackground">@color/ic_launcher_background</item>\n'
       '        <item name="android:windowSplashScreenAnimatedIcon">@mipmap/ic_launcher_foreground</item>\n'
       '    </style>\n</resources>\n')
put(f'{RES}/values-v31/styles.xml', v31)
put(f'{RES}/values-night-v31/styles.xml', v31)
print('icons ok')
