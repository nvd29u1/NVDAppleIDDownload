// C API of rust/sayoidev (iOS 27 on-device pairing and installs through the pairing tunnel).
#ifndef SAYOIDEV_H
#define SAYOIDEV_H
#include <stddef.h>
#include <stdint.h>

typedef struct SayoCancel SayoCancel;
typedef void (*sayo_idev_ready_cb)(uint16_t port, const char *json, void *ctx);
typedef void (*sayo_idev_pin_cb)(const char *pin, void *ctx);
typedef void (*sayo_idev_progress_cb)(uint64_t percent, const char *stage, void *ctx);

SayoCancel *sayo_idev_cancel_new(void);
void sayo_idev_cancel_signal(const SayoCancel *c);
void sayo_idev_cancel_free(SayoCancel *c);

/// Waits for this iPhone to pair (iOS 27: Settings → Developer Mode → "Pair with …").
/// `ready` gets the TCP port and JSON {"name": instance, "txt": {k: v}} to advertise as
/// _remotepairing-pairable-host._tcp. Returns 0, -1 (error, see err) or -2 (cancelled).
int32_t sayo_idev_pair_host(const char *name, const char *model, const char *out_path,
                            sayo_idev_ready_cb ready, sayo_idev_pin_cb pin, void *ctx,
                            const SayoCancel *cancel, char *err, size_t err_len);
/// Opens the pairing tunnel (LocalDevVPN) and reports how many services the device lists.
int32_t sayo_idev_check(const char *pairing_path, const char *addr, uint16_t port,
                        char *out, size_t out_len, char *err, size_t err_len);
/// Uploads and installs an IPA through the pairing tunnel (works with free Apple ID profiles).
int32_t sayo_idev_install(const char *pairing_path, const char *addr, uint16_t port,
                          const char *ipa_path, sayo_idev_progress_cb progress, void *ctx,
                          char *err, size_t err_len);
#endif
