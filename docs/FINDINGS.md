# What we found about the Pocket 3 in webcam mode

Measured on one Osmo Pocket 3 connected to a Mac running macOS 15. None of it is documented by DJI, and a firmware update could change any of it.

## USB

- **Identity:** USB vendor `0x2CA3`, product `0x0023`, name `DJIPocket3`. In webcam mode it shows only UVC video (control + streaming) and UAC audio interfaces. There is no vendor or DJI data interface.
- **UVC Camera Terminal (entity 1):**

  | Control | Selector | Format | Notes |
  | --- | --- | --- | --- |
  | Zoom (absolute) | 11 | uint16, ×100 | 1.0–4.0× |
  | Pan/tilt (absolute) | 13 | two int32, arcseconds (3,600 per degree) | sub-degree values work; no relative pan/tilt control |
  | Roll (absolute) | 15 | int16, degrees | |

  Requests: GET_CUR `0x81`, GET_MIN `0x82`, GET_MAX `0x83`, GET_INFO `0x86`. Each set or get takes about 18 ms. [server/uvcctl.c](../server/uvcctl.c) sends them without opening the device, so it works while another app streams video.

- **Holding a position:** the gimbal holds a commanded pan/tilt only while it keeps receiving it. Stop sending and it returns to its own follow behaviour within a few seconds.
- **Pan range by facing:** about −35° to 40° when facing front, and 145° to 215° in selfie. A pan command never switches sides; front/selfie is chosen on the camera.
- **Tilt is a joint angle:** it's the lens relative to the body, not the lens relative to the ground. After a move and a release, the gimbal often keeps that joint angle instead of re-levelling.
- **Selfie → front flips:** the camera flips itself from selfie to front when the body leans far forward (roughly past 45°), sometimes on the next move command, sometimes on its own.
- **Portrait video:** with the screen turned vertical, the camera sends 1080×1920 video. Most apps show a centred 16:9 crop of it.
- **Extension Unit (entity 6):** two selectors (1 and 2), 16 bytes each, GET/SET. They look like a command mailbox but never changed when ActiveTrack was toggled, and never answered read-only DJI "get version" queries written into them. We left them alone.

## Bluetooth

- **Commands:** in webcam mode the camera ignores DJI command frames, including reads.
- **Gimbal status:** it broadcasts gimbal status several times a second: DJI frame, command set `0x04`, id `0x05`, 49-byte payload.
  - The float quaternion at payload bytes 24–39 mirrors the gimbal's joint angles.
  - The value at payload byte 22 follows the **body's** forward tilt immediately and ignores lens moves. It reads about 6 upright and about 64 at about 40°, which fits 100·sin(lean). We didn't pin down its exact scale.

## Things we couldn't do

| Goal | Result |
| --- | --- |
| Toggle ActiveTrack from the Mac | Not exposed over USB, and Bluetooth ignores commands in webcam mode. Pocket3Bar's own face tracking replaces it (turn ActiveTrack off on the camera). |
| Stop charging at 80% | No setting, no documented command, and no reply from the vendor mailbox. Cutting a hub port's power also disconnects the webcam. |
| A reliable body lean meter | The joint angle lags and doesn't re-level. The Bluetooth tilt value works, but its scale is unknown, so we dropped the feature. |

## Mac-side gotchas

- **Checking "in use" is slow:** CoreMediaIO's "is the camera in use" check spends several seconds connecting to camera extensions in each new process (more with iPhone Continuity cameras). Ask from one long-running process. In Swift, `AVCaptureDevice.isInUseByAnotherApplication` gives the same signal and ignores your own app's use.
- **Preview layers:** creating or destroying an `AVCaptureVideoPreviewLayer` while its session is starting on another queue crashes AVFoundation. Create one layer up front and reuse it.
- **Popover sizing:** in an `NSPopover`, a flexible SwiftUI view with only an aspect ratio gets zero height. Give the preview a fixed size.
- **Signing:** an ad-hoc signature changes on every build, so macOS asks for camera permission again each time. A stable self-signed identity fixes it (see `scripts/make-signing-identity.sh`).
