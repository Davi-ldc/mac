# wallpaper

Ultra-optimized way to have a video as your wallpaper on a Mac.

20% less power, 4× less memory and 175× smaller on disk than Phosphene (M5 Max).

## Quickstart

```sh
xcode-select --install   # clang and make
brew install ffmpeg
git clone https://github.com/Davi-ldc/mac && cd mac/wallpaper
scripts/install.sh ~/Movies/your-video.mov
```

Remove it with `scripts/uninstall.sh`.
