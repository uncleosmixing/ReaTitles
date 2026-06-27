import sys
import os
import urllib.request
import time

FILES = [
    "config.json",
    "preprocessor_config.json",
    "tokenizer.json",
    "vocabulary.json",
    "model.bin"
]

BASE_URL = "https://huggingface.co/Systran/faster-whisper-large-v3/resolve/main/"

def download_file(url, dest):
    dest_dir = os.path.dirname(dest)
    if dest_dir and not os.path.exists(dest_dir):
        os.makedirs(dest_dir, exist_ok=True)
        
    filename = os.path.basename(dest)
    print(f"Downloading {filename}...")
    
    # Custom progress hook writing to sys.stdout
    start_time = time.time()
    def reporthook(block_num, block_size, total_size):
        if total_size <= 0:
            return
        downloaded = block_num * block_size
        percent = min(100.0, (downloaded / total_size) * 100.0)
        
        # Calculate speed
        elapsed = time.time() - start_time
        speed = (downloaded / (1024 * 1024)) / elapsed if elapsed > 0 else 0
        
        # Format sizes
        downloaded_mb = downloaded / (1024 * 1024)
        total_mb = total_size / (1024 * 1024)
        
        sys.stdout.write(
            f"\rProgress: {percent:.1f}% ({downloaded_mb:.1f} MB / {total_mb:.1f} MB) | Speed: {speed:.2f} MB/s | Elapsed: {elapsed:.0f}s    "
        )
        sys.stdout.flush()

    try:
        # User-Agent is needed sometimes to bypass basic bot blockers on HuggingFace CDN
        opener = urllib.request.build_opener()
        opener.addheaders = [('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)')]
        urllib.request.install_opener(opener)
        
        urllib.request.urlretrieve(url, dest, reporthook)
        print(f"\nSuccessfully downloaded {filename}")
    except Exception as e:
        print(f"\nError downloading {filename}: {e}")
        raise e

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    dest_dir = os.path.join(script_dir, "models", "large-v3")
    
    print("=== ReaTitles large-v3 Offline Model Downloader ===")
    print(f"Target directory: {dest_dir}\n")
    
    for filename in FILES:
        url = BASE_URL + filename
        dest_path = os.path.join(dest_dir, filename)
        
        # If file already exists and is not empty, skip downloading it
        if os.path.exists(dest_path) and os.path.getsize(dest_path) > 0:
            # For model.bin, check if it's at least 2.5 GB to make sure it's not a corrupt partial download
            if filename == "model.bin" and os.path.getsize(dest_path) < 2.5 * 1024 * 1024 * 1024:
                print(f"File {filename} exists but seems corrupt or incomplete (size: {os.path.getsize(dest_path) / (1024*1024):.1f} MB). Re-downloading...")
            else:
                print(f"File {filename} is already downloaded. Skipping.")
                continue
                
        try:
            download_file(url, dest_path)
        except KeyboardInterrupt:
            print("\nDownload cancelled by user.")
            sys.exit(1)
        except Exception:
            print("\nDownload failed. Please check your internet connection and try again.")
            sys.exit(1)
            
    print("\nAll files downloaded successfully!")
    print(f"Whisper 'large-v3' model is now fully cached at: {dest_dir}")
    print("You can close this window and run transcription in REAPER.")

if __name__ == "__main__":
    main()
