# Photopass Uploader

Photopass Uploader is a small macOS-friendly workflow for sorting and uploading event photos tied to QR-code photo pass cards. (see [this recipe](https://community.rockrms.com/subscriptions/rx2022/digital-photopass-powered-by-rock) for more details on the Rock side)

The intended photography flow is:

1. The photographer shoots one or more photos of a card with a unique QR code on it.
2. The photographer shoots the family or group photos that belong to that card.
3. The next QR card starts the next photo group.

The sorter scans the folder in capture order, detects QR codes, groups photos by QR code, and moves them into folders named after the code. Photos before the first readable QR, or photos that cannot be assigned to a readable QR group, go into an `unknown` folder.

QR card photos are renamed to `_QR-{CODE}` so later upload steps can skip them.

## Running the GUI

Launch the GUI with:

```bash
./run_photo_pass_gui.sh
```

The GUI supports:

- choosing a photo folder,
- sorting photos,
- upload dry-runs,
- uploading photos,
- verbose output,
- stopping long-running work,
- editing upload settings.

Typical GUI workflow:

1. Click `Upload Settings` and fill in the Rock/API configuration.
2. Click `Choose Folder` and select the folder of photos.
3. Click `Sort Photos`.
4. Review the scan summary.
5. Confirm the move if the summary looks correct.
6. Click `Upload Dry Run` to preview which photos will upload.
7. Click `Upload Photos` to upload the sorted photos to Rock.

The `Dry Run` checkbox applies to both sorting and uploading. The `Verbose` checkbox shows per-file details.

## Upload Configuration

Upload settings are stored in:

```text
upload_config.env
```

This file is intentionally ignored by git because it contains secrets.

Create it either through the GUI by clicking `Upload Settings`, or copy the example:

```bash
cp upload_config.env.example upload_config.env
```

Required config values:

```env
ROCK_URL="https://rock.valorouschurch.com"
ROCK_API_KEY="your-api-key"
FILE_TYPE_GUID="db67dde1-e078-4b1b-848f-986110a804b0"
WORKFLOW_TYPE_ID="256"
FILE_ATTRIBUTE_KEY="Image"
CODE_ATTRIBUTE_KEY="Code"
```

Environment variables with the same names override values from `upload_config.env`.

You can also point the uploader at a different config file:

```bash
UPLOAD_CONFIG_FILE=/path/to/upload_config.env ./upload_photos.sh /path/to/sorted-folder
```

## Rock API Permissions

Your Rock API key will need to have the following permissions at a minimum:

- Edit permissions for the File Type you are using
- Edit permissions to the Rest Controller: POST `api/Workflows/WorkflowEntry/{WorkflowTypeId}`

## Command Line Usage

The GUI is the easiest way to run the workflow, but the sorter and uploader can also be run directly from Terminal.

### Sort Photos

Run the sorter:

```bash
./photo_pass.swift /path/to/photo-folder
```

By default, the script:

- scans all supported images in capture order,
- prints a summary,
- warns about suspicious groups,
- asks for confirmation before moving files.

To skip the confirmation prompt:

```bash
./photo_pass.swift /path/to/photo-folder -y
```

To preview without moving files:

```bash
./photo_pass.swift /path/to/photo-folder --dry-run
```

To print each planned or completed move:

```bash
./photo_pass.swift /path/to/photo-folder --verbose
```

Useful options:

```bash
./photo_pass.swift /path/to/photo-folder --recursive
./photo_pass.swift /path/to/photo-folder --unknown-folder unreadable
```

### Upload Photos

After sorting, upload the sorted folder:

```bash
./upload_photos.sh /path/to/sorted-photo-folder
```

By default, the uploader:

- recursively finds uploadable image files,
- skips `_QR-*` marker images,
- skips files in an `unknown` folder,
- uploads each image to Rock,
- starts the configured workflow for each uploaded image,
- passes the folder name as the configured code attribute.

Preview the files that would upload:

```bash
./upload_photos.sh --dry-run /path/to/sorted-photo-folder
```

Show more detail:

```bash
./upload_photos.sh --verbose /path/to/sorted-photo-folder
```

Include QR marker images or unknown photos if needed:

```bash
./upload_photos.sh --include-qr /path/to/sorted-photo-folder
./upload_photos.sh --include-unknown /path/to/sorted-photo-folder
```

## Upload Workflow Details

For each image, `upload_photos.sh` performs two requests:

1. Upload the file:

```text
POST {ROCK_URL}/ImageUploader.ashx?isBinaryFile=T&fileId=&fileTypeGuid={FILE_TYPE_GUID}
```

2. Start the workflow:

```text
POST {ROCK_URL}/api/workflows/workflowentry/{WORKFLOW_TYPE_ID}?{FILE_ATTRIBUTE_KEY}={uploadedFileGuid}&{CODE_ATTRIBUTE_KEY}={folderCode}
```

The `folderCode` is the name of the folder the image was sorted into.

## Files

- `photo_pass.swift`: Sorts photos into QR-code folders.
- `photo_pass_gui.swift`: SwiftUI GUI for sorting and uploading.
- `run_photo_pass_gui.sh`: Compiles and launches the GUI.
- `upload_photos.sh`: Uploads sorted photos to Rock and starts the configured workflow.
- `upload_config.env.example`: Example upload configuration file.
- `upload_config.env`: Local upload configuration file. This file is ignored by git.
