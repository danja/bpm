cd ~/github/bpm 

flutter clean
flutter pub get
flutter build apk --release 

flutter build apk --debug

cp -r build/app/outputs/flutter-apk/* apk/

flutter analyze

flutter test

flutter test --reporter compact > test-results.txt


adb install -r apk/app-release.apk

adb install -r apk/app-debug.apk

adb uninstall com.example.bpm

 adb shell pm list packages | grep -i bpm




  Read the following : README.md docs/PLAN-03.md docs/algorithms.md docs/PROGRESS.md and revise CLAUDE.md with information useful for an agent working on the code. We are using synthesized audio and data files under data/ to test. The wavelet algorithm tends to be fairly accurate but the consensus algorithm isn't currently very good, the Predominant Pulse parts have just been added, they need integrating properly to make the UI consistent. Just now we were working through why wavelet tolerance isn't applying the higher percentTolerance value and still showing the old fixed tolerance in failure messages. I’m planning to add debug prints for the computed allowed tolerance to verify what values the test uses during execution. This will help pinpoint if the new percentTolerance is applied correctly or if some legacy constant or compilation quirk is causing the mismatch. 