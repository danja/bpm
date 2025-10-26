cd ~/github/bpm 

flutter clean
flutter pub get
flutter build apk --release

cp -r build/app/outputs/flutter-apk/* apk/

flutter analyze

flutter test




