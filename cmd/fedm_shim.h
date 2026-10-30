/*
 * fedm_shim.h
 *
 * Plain C interface to the FEIG FEDM C++ SDK.
 *
 * This header is included from a Go cgo preamble, so it must stay
 * C-compatible (no C++ types in the exported signatures).
 * The C++ implementation lives in fedm_shim.cpp.
 */
#ifndef FEDM_SHIM_H
#define FEDM_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

/* Return codes */
#define FEDM_SHIM_OK            0
#define FEDM_SHIM_ERR           -1  /* library error, see fedm_last_error_text() */
#define FEDM_SHIM_NOT_CONNECTED -2  /* no reader connected */
#define FEDM_SHIM_TAG_NOT_FOUND -3  /* tag UID not in last inventory */
#define FEDM_SHIM_NO_READER     -4  /* no reader found during discovery */
#define FEDM_SHIM_QUEUE_EMPTY   -5  /* discovery queue is empty */

/* A tag from the last inventory (fedm_inventory) */
typedef struct {
    char iddHex[17]; /* 8-byte UID as 16 hex chars, null-terminated */
    int  trType;     /* transponder type, see FEDM::TransponderType */
    int  dsfid;      /* ISO15693 DSFID, -1 if not available */
} FedmTag;

/* A Bluetooth LE reader from the discovery queue */
typedef struct {
    char mac[32];        /* e.g. "AA:BB:CC:DD:EE:FF" */
    char deviceId[16];   /* device id (serial) as hex string */
    char readerType[64]; /* reader type as string */
    int  state;          /* 1 = new reader, -1 = reader gone */
} FedmBleItem;

/* A USB reader from the discovery queue */
typedef struct {
    char deviceId[16];   /* device id (serial) as hex string */
    char readerType[64]; /* reader type as string */
    int  state;          /* 1 = plugged, -1 = unplugged */
} FedmUsbItem;

/* Library info */
int fedm_lib_version(char *buf, int len);

/*
 * Connection control.
 * All connect functions create a new reader module, connect to the reader
 * and read the reader identification and info.
 * Returns FEDM_SHIM_OK on success, a negative FEDM_SHIM_* code on error.
 */
int fedm_connect_usb(void);
int fedm_connect_tcp(const char *host, int port);
int fedm_connect_com(const char *port, const char *frame, int baud);
int fedm_connect_ble(const char *mac);
int fedm_disconnect(void);
int fedm_is_connected(void);

/*
 * Reader info. Returns 0 on success, FEDM_SHIM_NOT_CONNECTED if no reader
 * is connected. The buffer is always null-terminated.
 */
int fedm_reader_serial(char *buf, int len);
int fedm_reader_name(char *buf, int len);
int fedm_reader_fwversion(char *buf, int len);

/* Last library error / reader status text */
int fedm_last_error_text(char *buf, int len);
int fedm_last_status_text(char *buf, int len);

/*
 * Tag operations (ISO15693).
 *
 * fedm_inventory:    performs an inventory, fills up to maxTags entries in out
 *                    and returns the number of tags found.
 *                    Returns FEDM_SHIM_ERR on library error.
 * fedm_tag_read:     reads data blocks 0..8 of the tag with the given UID
 *                    (must be from the last inventory).
 *                    Returns the number of bytes read, negative on error.
 * fedm_tag_write:    writes the given data to the tag with the given UID,
 *                    starting at data block 0. Data length must be a multiple
 *                    of 4. Returns FEDM_SHIM_OK on success.
 * fedm_tag_write_afi / fedm_tag_reset_to_ready / fedm_tag_stay_quiet:
 *                    non-addressed (broadcast) ISO15693 commands, i.e. they
 *                    apply to all tags in range.
 */
int fedm_inventory(FedmTag *out, int maxTags);
int fedm_tag_read(const unsigned char *idd, int iddLen, unsigned char *out, int outLen);
int fedm_tag_write(const unsigned char *idd, int iddLen, const unsigned char *data, int dataLen);
int fedm_tag_write_afi(unsigned char afi);
int fedm_tag_reset_to_ready(void);
int fedm_tag_stay_quiet(void);

/*
 * Bluetooth LE discovery (FEDM::BluetoothLeManager).
 * Discovery runs in a background thread and fills an event queue.
 * fedm_ble_pop() consumes the queue; poll it after start to list readers.
 */
int fedm_ble_start_discover(void);
int fedm_ble_stop_discover(void);
int fedm_ble_reader_count(void);
int fedm_ble_pop(FedmBleItem *out);
int fedm_ble_last_error(char *buf, int len);

/*
 * USB discovery (FEDM::UsbManager), plug / unplug events.
 */
int fedm_usb_start_discover(void);
int fedm_usb_stop_discover(void);
int fedm_usb_reader_count(void);
int fedm_usb_pop(FedmUsbItem *out);

#ifdef __cplusplus
}
#endif

#endif /* FEDM_SHIM_H */
