cd ~/github/bpm 

flutter clean
flutter pub get
flutter build apk --release 

flutter build apk --debug

cp -r build/app/outputs/flutter-apk/* apk/

flutter analyze

flutter test

adb install -r apk/app-release.apk

adb install -r apk/app-debug.apk

adb uninstall com.example.bpm

 adb shell pm list packages | grep -i bpm


