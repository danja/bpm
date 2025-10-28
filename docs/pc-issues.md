Short-term workarounds (to get your build working):

  1. Free up disk space immediately
  # Clean Flutter cache
  flutter clean

  # Clean Gradle cache
  rm -rf ~/.gradle/caches

  # Clean Docker if you use it
  docker system prune -a
  2. Disable CPU core 4 (isolate the problematic core)
  echo 0 | sudo tee /sys/devices/system/cpu/cpu4/online
  3. Run filesystem repairs
  sudo umount /space
  sudo e2fsck -f -y -v /dev/sdc
  sudo mount /space

  Long-term fixes (required):

  1. Test RAM immediately - Run memtest86+ from boot menu or:
  sudo apt install memtester
  sudo memtester 1G 5  # Test 1GB, 5 passes
  2. Replace failing RAM - If memtest shows errors, replace all RAM modules
  3. Check disk SMART status
  sudo smartctl -a /dev/sdc | grep -E "Reallocated|Current_Pending|Offline_Uncorrectable"
  4. Consider hardware upgrade - This 13-year-old system is past its reliable lifespan

  Try This Now

  To attempt the Flutter build with mitigations:
  # Disable problematic CPU core
  echo 0 | sudo tee /sys/devices/system/cpu/cpu4/online

  # Free up space
  flutter clean

  # Try build with reduced parallelism
  flutter build apk --release --no-tree-shake-icons

  The root cause is almost certainly failing RAM. Memory corruption leads to random segfaults and filesystem corruption during intensive I/O operations
  like Flutter builds.
