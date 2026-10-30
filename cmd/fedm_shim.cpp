/*
 * fedm_shim.cpp
 *
 * C++ implementation of the plain C interface in fedm_shim.h.
 * Wraps the FEIG FEDM C++ SDK (Fedm.h) for use from Go via cgo.
 *
 * Threading model: the Go side serializes all reader operations with a
 * mutex (one operation at a time on a Reader). The mutex below is a
 * backstop protecting the global state from the discovery threads.
 */

#include <algorithm>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "fedm/Fedm.h"
#include "fedm_shim.h"

namespace {

struct FedmState {
    std::mutex mtx;
    std::unique_ptr<FEDM::ReaderModule> rdr;
    std::vector<FEDM::TagItem> tags; /* snapshot of last inventory */
    std::string lastErrText;
};

FedmState g_state;

bool connected() { return g_state.rdr && g_state.rdr->isConnected(); }

void copyStr(char *buf, int len, const std::string &s) {
    if (buf == nullptr || len <= 0) {
        return;
    }
    std::strncpy(buf, s.c_str(), static_cast<size_t>(len) - 1);
    buf[len - 1] = '\0';
}

/*
 * Last error or status text of the reader module
 * (FEDM::ReaderModule::lastErrorStatusText: text of the last library error,
 * ISO error or reader status)
 */
std::string lastErrorText() {
    if (g_state.rdr) {
        return g_state.rdr->lastErrorStatusText();
    }
    return g_state.lastErrText;
}

void setErr(const std::string &text) { g_state.lastErrText = text; }

/* Create a new reader module and connect it with the given connector. */
int createAndConnect(const FEDM::Connector &connector) {
    g_state.rdr.reset();
    g_state.tags.clear();
    g_state.rdr = std::make_unique<FEDM::ReaderModule>(FEDM::RequestMode::UniDirectional);

    int ret = g_state.rdr->connect(connector);
    if (ret < 0) {
        setErr(lastErrorText());
        return FEDM_SHIM_ERR;
    }

    // Use the tag table for inventory results (snapshot in fedm_inventory)
    g_state.rdr->hm().setUsageMode(FEDM::Hm::UsageMode::UseTable);

    // Read identification and full reader info. connect() already reads a
    // minimum set depending on the connector's reader info policy; these
    // calls make sure we have all fields for display. Non-fatal on failure.
    if (g_state.rdr->readReaderIdentification() < 0) {
        setErr(lastErrorText());
    }
    if (g_state.rdr->readReaderInfo() < 0) {
        setErr(lastErrorText());
    }
    return FEDM_SHIM_OK;
}

/* Find the tag from the last inventory snapshot with the given UID. */
const FEDM::TagItem *findTagItem(const unsigned char *idd, int iddLen) {
    if (idd == nullptr || iddLen <= 0) {
        return nullptr;
    }
    std::vector<uint8_t> key(idd, idd + iddLen);
    for (const auto &t : g_state.tags) {
        if (t.idd() == key) {
            return &t;
        }
    }
    return nullptr;
}

/* Create an addressed tag handler for the tag with the given UID. */
std::unique_ptr<FEDM::TagHandler::ThBase> createTagHandler(const unsigned char *idd, int iddLen) {
    const FEDM::TagItem *found = findTagItem(idd, iddLen);
    if (found == nullptr) {
        return nullptr;
    }
    return g_state.rdr->hm().createTagHandler(*found);
}

/* Create a non-addressed (broadcast) ISO15693 tag handler. */
std::unique_ptr<FEDM::TagHandler::ThIso15693> createNonAddressedTagHandler() {
    auto thBase = g_state.rdr->hm().createNonAddressedTagHandler(FEDM::TagHandler::ThBase::TypeIso15693);
    if (!thBase) {
        return nullptr;
    }
    // Cast while thBase still owns the object, only take ownership on success
    auto p = dynamic_cast<FEDM::TagHandler::ThIso15693 *>(thBase.get());
    if (!p) {
        return nullptr;
    }
    thBase.release();
    return std::unique_ptr<FEDM::TagHandler::ThIso15693>(p);
}

} // namespace

/* ------------------------------------------------------------------ */
/* Library info                                                        */
/* ------------------------------------------------------------------ */

extern "C" int fedm_lib_version(char *buf, int len) {
    copyStr(buf, len, FEDM::Utility::LibInfo::libVersion());
    return FEDM_SHIM_OK;
}

/* ------------------------------------------------------------------ */
/* Connection control                                                  */
/* ------------------------------------------------------------------ */

extern "C" int fedm_connect_usb(void) {
    std::lock_guard<std::mutex> lock(g_state.mtx);

    // Stop any previous discovery, then start a new one (initial enumeration).
    FEDM::UsbManager::stopDiscover();
    int ret = FEDM::UsbManager::startDiscover(nullptr);
    if (ret < 0) {
        setErr(FEDM::UsbManager::lastErrorText());
        return FEDM_SHIM_ERR;
    }

    int found = 0;
    FEDM::Connector connector;
    while (FEDM::UsbManager::readerCount() > 0) {
        FEDM::UsbScanInfo info = FEDM::UsbManager::popDiscover();
        if (info.isValid() && info.isNewReader()) {
            connector = info.connector();
            found = 1;
            break;
        }
    }
    FEDM::UsbManager::stopDiscover();

    if (!found) {
        setErr("no USB reader found");
        return FEDM_SHIM_NO_READER;
    }
    return createAndConnect(connector);
}

extern "C" int fedm_connect_tcp(const char *host, int port) {
    std::lock_guard<std::mutex> lock(g_state.mtx);
    if (host == nullptr) {
        setErr("tcp: host is null");
        return FEDM_SHIM_ERR;
    }
    FEDM::Connector connector = FEDM::Connector::createTcpConnector(std::string(host), port);
    connector.setTcpConnectTimeout(5000);
    return createAndConnect(connector);
}

extern "C" int fedm_connect_com(const char *port, const char *frame, int baud) {
    std::lock_guard<std::mutex> lock(g_state.mtx);
    if (port == nullptr) {
        setErr("com: port is null");
        return FEDM_SHIM_ERR;
    }
    std::string f = (frame != nullptr) ? std::string(frame) : std::string("8E1");
    FEDM::Connector connector = FEDM::Connector::createComConnector(std::string(port), f, baud, 255);
    return createAndConnect(connector);
}

extern "C" int fedm_connect_ble(const char *mac) {
    std::lock_guard<std::mutex> lock(g_state.mtx);
    if (mac == nullptr) {
        setErr("ble: mac is null");
        return FEDM_SHIM_ERR;
    }
    FEDM::Connector connector = FEDM::Connector::createBluetoothLeConnector(std::string(mac));
    return createAndConnect(connector);
}

extern "C" int fedm_disconnect(void) {
    std::lock_guard<std::mutex> lock(g_state.mtx);
    if (!g_state.rdr) {
        return FEDM_SHIM_OK;
    }
    g_state.rdr->terminate();
    g_state.rdr->disconnect();
    g_state.rdr.reset();
    g_state.tags.clear();
    return FEDM_SHIM_OK;
}

extern "C" int fedm_is_connected(void) {
    std::lock_guard<std::mutex> lock(g_state.mtx);
    return connected() ? FEDM_SHIM_OK : FEDM_SHIM_NOT_CONNECTED;
}

/* ------------------------------------------------------------------ */
/* Reader info                                                         */
/* ------------------------------------------------------------------ */

extern "C" int fedm_reader_serial(char *buf, int len) {
    std::lock_guard<std::mutex> lock(g_state.mtx);
    if (!connected()) {
        return FEDM_SHIM_NOT_CONNECTED;
    }
    std::string s;
    FEDM::ReaderIdentification id = g_state.rdr->identification();
    if (id.isValid()) {
        s = id.deviceIdToHexString();
    }
    if (s.empty()) {
        s = g_state.rdr->info().deviceIdToHexString();
    }
    copyStr(buf, len, s);
    return FEDM_SHIM_OK;
}

extern "C" int fedm_reader_name(char *buf, int len) {
    std::lock_guard<std::mutex> lock(g_state.mtx);
    if (!connected()) {
        return FEDM_SHIM_NOT_CONNECTED;
    }
    std::string s;
    FEDM::ReaderIdentification id = g_state.rdr->identification();
    if (id.isValid()) {
        s = id.readerTypeToString();
    }
    if (s.empty()) {
        s = FEDM::ReaderType::toString(g_state.rdr->readerType());
    }
    copyStr(buf, len, s);
    return FEDM_SHIM_OK;
}

extern "C" int fedm_reader_fwversion(char *buf, int len) {
    std::lock_guard<std::mutex> lock(g_state.mtx);
    if (!connected()) {
        return FEDM_SHIM_NOT_CONNECTED;
    }
    std::string s;
    FEDM::ReaderIdentification id = g_state.rdr->identification();
    if (id.isValid()) {
        s = id.versionToString();
    }
    copyStr(buf, len, s);
    return FEDM_SHIM_OK;
}

extern "C" int fedm_last_error_text(char *buf, int len) {
    std::lock_guard<std::mutex> lock(g_state.mtx);
    copyStr(buf, len, lastErrorText());
    return FEDM_SHIM_OK;
}

extern "C" int fedm_last_status_text(char *buf, int len) {
    std::lock_guard<std::mutex> lock(g_state.mtx);
    copyStr(buf, len, lastErrorText());
    return FEDM_SHIM_OK;
}

/* ------------------------------------------------------------------ */
/* Tag operations                                                      */
/* ------------------------------------------------------------------ */

extern "C" int fedm_inventory(FedmTag *out, int maxTags) {
    std::lock_guard<std::mutex> lock(g_state.mtx);
    if (!connected()) {
        return FEDM_SHIM_NOT_CONNECTED;
    }
    if (out == nullptr || maxTags <= 0) {
        return FEDM_SHIM_ERR;
    }

    int ret = g_state.rdr->hm().inventory(true);
    if (ret < 0) {
        setErr(lastErrorText());
        return FEDM_SHIM_ERR;
    }
    // ret > 0: reader signaled a problem (see ReaderStatus), may still have tags

    size_t count = 0;
    try {
        count = g_state.rdr->hm().itemCount();
    } catch (const std::exception &e) {
        setErr(e.what());
        return FEDM_SHIM_ERR;
    }

    // Snapshot the tag table into g_state.tags while we are in the same
    // call as inventory() (the tag table is only guaranteed accessible
    // from the thread that called inventory).
    g_state.tags.clear();
    size_t n = std::min(count, static_cast<size_t>(maxTags));
    for (size_t i = 0; i < n; i++) {
        try {
            const FEDM::TagItem &t = g_state.rdr->hm().tagItem(i);
            g_state.tags.push_back(t);
            out[i].iddHex[0] = '\0';
            copyStr(out[i].iddHex, sizeof(out[i].iddHex), t.iddToHexString());
            out[i].trType = t.trType();
            out[i].dsfid = t.iso15693_DsfId();
        } catch (const std::exception &) {
            n = i;
            break;
        }
    }
    return static_cast<int>(n);
}

extern "C" int fedm_tag_read(const unsigned char *idd, int iddLen, unsigned char *out, int outLen) {
    std::lock_guard<std::mutex> lock(g_state.mtx);
    if (!connected()) {
        return FEDM_SHIM_NOT_CONNECTED;
    }
    if (out == nullptr || outLen <= 0) {
        return FEDM_SHIM_ERR;
    }

    auto thBase = createTagHandler(idd, iddLen);
    if (!thBase) {
        return FEDM_SHIM_TAG_NOT_FOUND;
    }
    auto th = dynamic_cast<FEDM::TagHandler::ThIso15693 *>(thBase.get());
    if (!th) {
        setErr("not an ISO15693 transponder");
        return FEDM_SHIM_ERR;
    }

    size_t blockSize = 0;
    std::vector<uint8_t> data;
    int ret = th->readMultipleBlocks(0, 9, blockSize, data);
    if (ret < 0) {
        setErr(lastErrorText());
        return FEDM_SHIM_ERR;
    }
    size_t n = std::min(data.size(), static_cast<size_t>(outLen));
    std::memcpy(out, data.data(), n);
    return static_cast<int>(n);
}

extern "C" int fedm_tag_write(const unsigned char *idd, int iddLen, const unsigned char *data, int dataLen) {
    std::lock_guard<std::mutex> lock(g_state.mtx);
    if (!connected()) {
        return FEDM_SHIM_NOT_CONNECTED;
    }
    if (data == nullptr || dataLen <= 0 || dataLen % 4 != 0) {
        return FEDM_SHIM_ERR;
    }

    auto thBase = createTagHandler(idd, iddLen);
    if (!thBase) {
        return FEDM_SHIM_TAG_NOT_FOUND;
    }
    auto th = dynamic_cast<FEDM::TagHandler::ThIso15693 *>(thBase.get());
    if (!th) {
        setErr("not an ISO15693 transponder");
        return FEDM_SHIM_ERR;
    }

    std::vector<uint8_t> vdata(data, data + dataLen);
    int ret = th->writeMultipleBlocks(0, dataLen / 4, 4, vdata);
    if (ret < 0) {
        setErr(lastErrorText());
        return FEDM_SHIM_ERR;
    }
    return FEDM_SHIM_OK;
}

extern "C" int fedm_tag_write_afi(unsigned char afi) {
    std::lock_guard<std::mutex> lock(g_state.mtx);
    if (!connected()) {
        return FEDM_SHIM_NOT_CONNECTED;
    }
    auto th = createNonAddressedTagHandler();
    if (!th) {
        setErr(g_state.rdr ? lastErrorText() : "no tag handler");
        return FEDM_SHIM_ERR;
    }
    int ret = th->writeAFI(afi);
    if (ret < 0) {
        setErr(lastErrorText());
        return FEDM_SHIM_ERR;
    }
    return FEDM_SHIM_OK;
}

extern "C" int fedm_tag_reset_to_ready(void) {
    std::lock_guard<std::mutex> lock(g_state.mtx);
    if (!connected()) {
        return FEDM_SHIM_NOT_CONNECTED;
    }
    auto th = createNonAddressedTagHandler();
    if (!th) {
        setErr(g_state.rdr ? lastErrorText() : "no tag handler");
        return FEDM_SHIM_ERR;
    }
    int ret = th->resetToReady();
    if (ret < 0) {
        setErr(lastErrorText());
        return FEDM_SHIM_ERR;
    }
    return FEDM_SHIM_OK;
}

extern "C" int fedm_tag_stay_quiet(void) {
    std::lock_guard<std::mutex> lock(g_state.mtx);
    if (!connected()) {
        return FEDM_SHIM_NOT_CONNECTED;
    }
    auto th = createNonAddressedTagHandler();
    if (!th) {
        setErr(g_state.rdr ? lastErrorText() : "no tag handler");
        return FEDM_SHIM_ERR;
    }
    int ret = th->stayQuiet();
    if (ret < 0) {
        setErr(lastErrorText());
        return FEDM_SHIM_ERR;
    }
    return FEDM_SHIM_OK;
}

/* ------------------------------------------------------------------ */
/* Bluetooth LE discovery                                              */
/* ------------------------------------------------------------------ */

extern "C" int fedm_ble_start_discover(void) {
    std::lock_guard<std::mutex> lock(g_state.mtx);
    int ret = FEDM::BluetoothLeManager::startDiscover(nullptr);
    if (ret < 0) {
        setErr(FEDM::BluetoothLeManager::lastErrorText());
        return FEDM_SHIM_ERR;
    }
    return FEDM_SHIM_OK;
}

extern "C" int fedm_ble_stop_discover(void) {
    std::lock_guard<std::mutex> lock(g_state.mtx);
    int ret = FEDM::BluetoothLeManager::stopDiscover();
    if (ret < 0) {
        setErr(FEDM::BluetoothLeManager::lastErrorText());
        return FEDM_SHIM_ERR;
    }
    return FEDM_SHIM_OK;
}

extern "C" int fedm_ble_reader_count(void) {
    return static_cast<int>(FEDM::BluetoothLeManager::readerCount());
}

extern "C" int fedm_ble_pop(FedmBleItem *out) {
    std::lock_guard<std::mutex> lock(g_state.mtx);
    if (out == nullptr) {
        return FEDM_SHIM_ERR;
    }
    FEDM::BluetoothLeScanInfo info = FEDM::BluetoothLeManager::popDiscover();
    if (!info.isValid()) {
        return FEDM_SHIM_QUEUE_EMPTY;
    }
    out->mac[0] = '\0';
    out->deviceId[0] = '\0';
    out->readerType[0] = '\0';
    copyStr(out->mac, sizeof(out->mac), info.macAddress());
    copyStr(out->deviceId, sizeof(out->deviceId), info.deviceIdToHexString());
    copyStr(out->readerType, sizeof(out->readerType), info.readerTypeToString());
    out->state = info.isNewReader() ? 1 : (info.isReaderGone() ? -1 : 0);
    return FEDM_SHIM_OK;
}

extern "C" int fedm_ble_last_error(char *buf, int len) {
    std::lock_guard<std::mutex> lock(g_state.mtx);
    copyStr(buf, len, FEDM::BluetoothLeManager::lastErrorText());
    return FEDM_SHIM_OK;
}

/* ------------------------------------------------------------------ */
/* USB discovery                                                       */
/* ------------------------------------------------------------------ */

extern "C" int fedm_usb_start_discover(void) {
    std::lock_guard<std::mutex> lock(g_state.mtx);
    int ret = FEDM::UsbManager::startDiscover(nullptr);
    if (ret < 0) {
        setErr(FEDM::UsbManager::lastErrorText());
        return FEDM_SHIM_ERR;
    }
    return FEDM_SHIM_OK;
}

extern "C" int fedm_usb_stop_discover(void) {
    std::lock_guard<std::mutex> lock(g_state.mtx);
    int ret = FEDM::UsbManager::stopDiscover();
    if (ret < 0) {
        setErr(FEDM::UsbManager::lastErrorText());
        return FEDM_SHIM_ERR;
    }
    return FEDM_SHIM_OK;
}

extern "C" int fedm_usb_reader_count(void) {
    return static_cast<int>(FEDM::UsbManager::readerCount());
}

extern "C" int fedm_usb_pop(FedmUsbItem *out) {
    std::lock_guard<std::mutex> lock(g_state.mtx);
    if (out == nullptr) {
        return FEDM_SHIM_ERR;
    }
    FEDM::UsbScanInfo info = FEDM::UsbManager::popDiscover();
    if (!info.isValid()) {
        return FEDM_SHIM_QUEUE_EMPTY;
    }
    out->deviceId[0] = '\0';
    out->readerType[0] = '\0';
    copyStr(out->deviceId, sizeof(out->deviceId), info.deviceIdToHexString());
    copyStr(out->readerType, sizeof(out->readerType), info.readerTypeToString());
    out->state = info.isNewReader() ? 1 : (info.isReaderGone() ? -1 : 0);
    return FEDM_SHIM_OK;
}
