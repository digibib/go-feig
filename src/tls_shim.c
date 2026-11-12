/*
 * tls_shim.c
 *
 * Minimal server-side TLS for the feig http endpoint.
 *
 * Linux: OpenSSL, dlopen'd at runtime (tls_init), so the binary runs
 * without OpenSSL installed until -tls is actually used. All symbols
 * used exist in OpenSSL 1.1.0 and 3.x, so both are supported.
 *
 * Windows: SChannel (secur32/crypt32), loaded at runtime. The cert
 * must be a PEM file; the key must be PKCS#8 ("BEGIN PRIVATE KEY",
 * e.g. from `openssl genpkey -algorithm RSA -out key.pem` or
 * `openssl pkcs8 -topk8 -nocrypt`).
 *
 * The handshake runs on an already-accepted, blocking socket. The
 * socket stays owned by the caller (tls_free does not close it).
 *
 * Platform note: tls_accept takes the accepted socket as a void* on
 * both platforms (on linux the fd fits in the low bits of a pointer,
 * System V ABI), so the zig caller passes one type.
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>

static char g_err[256] = "no error";
static int g_last_err_code;

/* AF_INET socket address (identical layout in glibc and winsock),
 * used by feig_get_my_ip's UDP "connect" */
struct feig_sockaddr_in {
    unsigned short family;
    unsigned short port;
    unsigned int addr;
    unsigned char zero[8];
};

#ifndef _WIN32

/* ========== linux: OpenSSL (dlopen at runtime) ========== */

#include <dlfcn.h>

extern int close(int fd);
extern int write(int fd, const void *buf, size_t count);
extern int socket(int domain, int type, int protocol);
extern int connect(int sockfd, const void *addr, int addrlen);
extern int getsockname(int sockfd, void *addr, int *addrlen);

struct ssl_ctx_st;
struct ssl_st;
struct ssl_method_st;

static struct ssl_ctx_st *(*p_SSL_CTX_new)(const struct ssl_method_st *meth);
static const struct ssl_method_st *(*p_TLS_server_method)(void);
static int (*p_SSL_CTX_use_certificate_file)(struct ssl_ctx_st *ctx, const char *file, int type);
static int (*p_SSL_CTX_use_PrivateKey_file)(struct ssl_ctx_st *ctx, const char *file, int type);
static int (*p_SSL_CTX_check_private_key)(struct ssl_ctx_st *ctx);
static struct ssl_st *(*p_SSL_new)(struct ssl_ctx_st *ctx);
static int (*p_SSL_set_fd)(struct ssl_st *ssl, int fd);
static int (*p_SSL_accept)(struct ssl_st *ssl);
static int (*p_SSL_read)(struct ssl_st *ssl, void *buf, int num);
static int (*p_SSL_write)(struct ssl_st *ssl, const void *buf, int num);
static void (*p_SSL_free)(struct ssl_st *ssl);
static int (*p_SSL_get_error)(const struct ssl_st *ssl, int ret);
static void (*p_SSL_CTX_free)(struct ssl_ctx_st *ctx);
static unsigned long (*p_ERR_get_error)(void);
static void (*p_ERR_error_string_n)(const unsigned long e, char *buf, size_t num);

static struct ssl_ctx_st *g_ctx;

#define SSL_FILETYPE_PEM 1
#define SSL_ERROR_WANT_READ 2
#define SSL_ERROR_WANT_WRITE 3
#define SSL_ERROR_SYSCALL 5

/*
 * Load OpenSSL and build the server context from cert/key PEM files.
 * Returns 0 on success, -1 on error (see tls_last_error).
 */
int tls_init(const char *cert_file, const char *key_file) {
    g_last_err_code = 0;
    void *h = dlopen("libssl.so.3", RTLD_NOW);
    if (!h) h = dlopen("libssl.so.1.1", RTLD_NOW);
    if (!h) h = dlopen("libssl.so", RTLD_NOW);
    if (!h) {
        const char *dlerr = dlerror();
        snprintf(g_err, sizeof g_err, "cannot load libssl: %s", dlerr ? dlerr : "unknown");
        return -1;
    }
#define RESOLVE(name) do { \
        p_##name = (typeof(p_##name)) dlsym(h, #name); \
        if (!p_##name) { \
            snprintf(g_err, sizeof g_err, "missing openssl symbol: %s", #name); \
            return -1; \
        } \
    } while (0)
    RESOLVE(SSL_CTX_new);
    RESOLVE(TLS_server_method);
    RESOLVE(SSL_CTX_use_certificate_file);
    RESOLVE(SSL_CTX_use_PrivateKey_file);
    RESOLVE(SSL_CTX_check_private_key);
    RESOLVE(SSL_new);
    RESOLVE(SSL_set_fd);
    RESOLVE(SSL_accept);
    RESOLVE(SSL_read);
    RESOLVE(SSL_write);
    RESOLVE(SSL_free);
    RESOLVE(SSL_get_error);
    RESOLVE(SSL_CTX_free);
    RESOLVE(ERR_get_error);
    RESOLVE(ERR_error_string_n);
#undef RESOLVE

    g_ctx = p_SSL_CTX_new(p_TLS_server_method());
    if (!g_ctx) {
        snprintf(g_err, sizeof g_err, "SSL_CTX_new failed");
        return -1;
    }
    if (p_SSL_CTX_use_certificate_file(g_ctx, cert_file, SSL_FILETYPE_PEM) != 1 ||
        p_SSL_CTX_use_PrivateKey_file(g_ctx, key_file, SSL_FILETYPE_PEM) != 1 ||
        p_SSL_CTX_check_private_key(g_ctx) != 1) {
        p_ERR_error_string_n(p_ERR_get_error(), g_err, sizeof g_err);
        p_SSL_CTX_free(g_ctx);
        g_ctx = NULL;
        return -1;
    }
    return 0;
}

/*
 * Run the server handshake on an accepted, blocking fd.
 * Returns the SSL handle on success, NULL on error (see tls_last_error).
 */
void *tls_accept(void *sock) {
    g_last_err_code = 0;
    if (!g_ctx) {
        strcpy(g_err, "tls_init not called");
        return NULL;
    }
    int fd = (int)(intptr_t)sock;
    struct ssl_st *ssl = p_SSL_new(g_ctx);
    if (!ssl) {
        strcpy(g_err, "SSL_new failed");
        return NULL;
    }
    if (p_SSL_set_fd(ssl, fd) != 1) {
        p_SSL_free(ssl);
        strcpy(g_err, "SSL_set_fd failed");
        return NULL;
    }
    if (p_SSL_accept(ssl) == 1) return ssl;
    g_last_err_code = p_SSL_get_error(ssl, 0);
    p_SSL_free(ssl);
    if (g_last_err_code == SSL_ERROR_SYSCALL) {
        strcpy(g_err, "handshake failed: connection closed or syscall error");
    } else {
        p_ERR_error_string_n(p_ERR_get_error(), g_err, sizeof g_err);
    }
    return NULL;
}

/*
 * Read/write over the TLS stream. Returns >0 for bytes transferred,
 * 0 for a clean peer close (read), negative on error. tls_last_err_code
 * then holds SSL_get_error(). The fd is blocking, so WANT_READ/WRITE do
 * not occur in practice.
 */
int tls_read(void *ssl, void *buf, int len) {
    int n = p_SSL_read((struct ssl_st *) ssl, buf, len);
    if (n <= 0) g_last_err_code = p_SSL_get_error((struct ssl_st *) ssl, n);
    return n;
}

int tls_write(void *ssl, const void *buf, int len) {
    int n = p_SSL_write((struct ssl_st *) ssl, buf, len);
    if (n <= 0) g_last_err_code = p_SSL_get_error((struct ssl_st *) ssl, n);
    return n;
}

void tls_free(void *ssl) {
    if (ssl) p_SSL_free((struct ssl_st *) ssl);
}

int feig_close_socket(void *sock) {
    return close((int)(intptr_t)sock);
}

int feig_sock_write(void *sock, const void *buf, int len) {
    return (int)write((int)(intptr_t)sock, buf, (size_t)len);
}

/*
 * Outbound IP: UDP "connect" (sends no packets) + getsockname.
 * Returns 0 on success with the dotted quad in buf.
 */
int feig_get_my_ip(char *buf, int len) {
    int s = socket(2 /*AF_INET*/, 2 /*SOCK_DGRAM*/, 0);
    if (s < 0) return -1;
    struct feig_sockaddr_in sa;
    memset(&sa, 0, sizeof sa);
    sa.family = 2; /* AF_INET */
    sa.addr = 0x01010101; /* 1.1.1.1, network order (palindrome: endian-safe) */
    if (connect(s, &sa, sizeof sa) != 0) {
        close(s);
        return -1;
    }
    struct feig_sockaddr_in local;
    int llen = (int)sizeof local;
    int rc = getsockname(s, &local, &llen);
    close(s);
    if (rc != 0) return -1;
    unsigned char *b = (unsigned char *)&local.addr;
    return snprintf(buf, (size_t)len, "%u.%u.%u.%u", b[0], b[1], b[2], b[3]);
}

#else

/* ========== windows: SChannel (runtime resolved) ==========
 *
 * zig's bundled windows-gnu sysroot ships a reduced win32 header set
 * and incomplete import libraries, so:
 *   - the SChannel/CryptoAPI struct layouts are declared here
 *     directly (stable x64 ones), and
 *   - all win32 functions are resolved at runtime with
 *     LoadLibraryA/GetProcAddress (kernel32, always linked), trying
 *     the A-suffixed and plain export names.
 * The only link-time dependencies are LoadLibraryA/GetProcAddress.
 */
#include <stdlib.h>

typedef unsigned long long SOCKET;
typedef void *PCCERT_CONTEXT;
typedef unsigned long long HCRYPTPROV;
typedef unsigned long long HCRYPTKEY;

typedef struct {
    unsigned long ulContextHandle;
    void *hContext;
} CtxtHandle;

typedef struct {
    unsigned long ulBufferType;
    unsigned long cbBuffer;
    void *pvBuffer;
} SecBuffer;

typedef struct {
    unsigned long ulVersion;
    unsigned long cBuffers;
    SecBuffer *pBuffers;
} SecBufferDesc;

/*
 * Only the first two fields are used (dwVersion = SCHANNEL_CRED_VERSION
 * with the server cert); the rest is zero padding so the function never
 * reads past the struct.
 */
typedef struct {
    unsigned long dwVersion;
    PCCERT_CONTEXT h_CERT;
    char pad[512];
} SChannelCred;

typedef struct {
    unsigned long cbData;
    unsigned char pbData[1];
} DerBlob;

typedef struct {
    unsigned long cbStruct;
    PCCERT_CONTEXT pCertContext;
    void *pPrivateKeyBlob;
    unsigned long pPrivateKeyBlobLen;
    void *pPublicKeyBlob;
    unsigned long pPublicKeyBlobLen;
} Pkcs8Import;

typedef struct {
    unsigned short wVersion;
    unsigned short wHighVersion;
    char szDescription[256];
    char szSystemStatus[128];
    unsigned int iMaxSockets;
    unsigned int iMaxUdpDgRcv;
    void *lpVendorInfo[4];
} WSADATA;

#define SEC_E_OK 0
#define SEC_I_CONTINUE_NEEDED 0x00090312
#define SECBUFFER_VERSION 0
#define SECBUFFER_DATA 1
#define SECBUFFER_EMPTY 4
#define LOCAL_WS_IP_ADDRESS 0
#define SCHANNEL_CRED_VERSION 1
#define CERT_X509_ASN_ENCODING 0x00000001
#define DECODE_FLAG_NOCHECK 0x00000008
#define PROV_RSA_FULL 24
#define CRYPT_VERIFYCONTEXT 0xF0000000
#define AT_KEYEXCHANGE 2
#define KEY_SPEC 13
#define WSAEINTR 10035

extern void *LoadLibraryA(const char *lpLibFileName);
extern void *GetProcAddress(void *hModule, const char *lpProcName);

struct winapi {
    int (*AcceptSecurityContext)(void *pCredential, void *pPreviousContext, void *pInput,
                                 unsigned long dwFlags, void *psInterface, void *pContext,
                                 void *pOutput, unsigned long *pAttrs, void *pExpiry);
    int (*DeleteSecurityContext)(void *pContext);
    int (*EncryptMessage)(void *pMessageDesc, unsigned long qwfFlags, void *pReserved, unsigned long dwReserved);
    int (*DecryptMessage)(void *pMessageDesc, void *pReserved, unsigned long qwfFlags, unsigned long dwFlags);
    void (*FreeContextBuffer)(void *pvContext);
    int (*CertDecodeCertificate)(unsigned long dwCertEncoding, const void *pvEncodedCert, PCCERT_CONTEXT *phCert);
    int (*CertFreeCertificateContext)(PCCERT_CONTEXT hCert);
    int (*CertSetCertificateContextProperty)(PCCERT_CONTEXT hCert, unsigned long dwPropId, const void *pvData, unsigned long dwFlags);
    int (*CryptAcquireContext)(HCRYPTPROV *phProv, const char *pszContainer, const char *pszProvider,
                               unsigned long dwProvType, unsigned long dwFlags);
    int (*CryptDecodeObject)(unsigned long dwEncodingType, const char *lpszStructType,
                             const void *pvEncodedInfo, unsigned long dwFlags, void *pvStructInfo);
    int (*CryptImportKey)(HCRYPTPROV hProv, const void *pbData, unsigned long cbData,
                          void *pPubIntf, unsigned long dwFlags, HCRYPTKEY *phKey);
    int (*CryptSetKeyProperties)(HCRYPTKEY hKey, const char *pszDesc, unsigned long dwProps, unsigned long dwReserved);
    int (*CryptReleaseContext)(HCRYPTPROV hProv, unsigned long dwFlags);
    int (*CryptDestroyKey)(HCRYPTKEY hKey);
    void *(*LocalFree)(void *hMem);
    int (*recv)(SOCKET s, void *buf, int len, int flags);
    int (*send)(SOCKET s, const void *buf, int len, int flags);
    int (*WSAGetLastError)(void);
    unsigned long (*GetLastError)(void);
};
static struct winapi W;
static void *g_secur32, *g_crypt32, *g_ws2_32, *g_kernel32;

/*
 * winsock must be started once per process before any ws2_32 call.
 * The zig net path has probably already started it (winsock state is
 * process-wide; the refcount only grows, so calling it again is
 * harmless), but the shim must not assume it: an uninitialized send
 * fails with 10093, and then closesocket fails too - the SSE delivery
 * thread would give up while the client's connection stays open
 * (exactly the windows /events/ hang).
 */
static int (*p_WSAStartup)(unsigned short, void *) = 0;
static int winsock_state = -1; /* -1 untried, 0 unavailable, 1 started */

static void ensureWinsock(void) {
    if (winsock_state >= 0) return;
    winsock_state = 0;
    void *m = LoadLibraryA("ws2_32.dll");
    if (!m) return;
    p_WSAStartup = (int (*)(unsigned short, void *))GetProcAddress(m, "WSAStartup");
    if (!p_WSAStartup) return;
    WSADATA wd;
    memset(&wd, 0, sizeof wd);
    wd.wVersion = 0x0202; /* 2.2 */
    if (p_WSAStartup(0x0202, &wd) == 0) winsock_state = 1;
}

static void *winSym(void **cache, const char *dll, const char *name) {
    if (!*cache) *cache = LoadLibraryA(dll);
    if (!*cache) return NULL;
    return GetProcAddress(*cache, name);
}

/* some exports only exist under the A-suffixed name (or vice versa) */
static void *winSym2(void **cache, const char *dll, const char *name1, const char *name2) {
    void *p = winSym(cache, dll, name1);
    if (!p) p = winSym(cache, dll, name2);
    return p;
}

#define RES(dllvar, dll, field, name) do { \
    W.field = (typeof(W.field))winSym(&g_##dllvar, dll, name); \
    if (!W.field) { snprintf(g_err, sizeof g_err, "cannot load %s:%s", dll, name); return -1; } \
} while (0)
#define RES2(dllvar, dll, field, name1, name2) do { \
    W.field = (typeof(W.field))winSym2(&g_##dllvar, dll, name1, name2); \
    if (!W.field) { snprintf(g_err, sizeof g_err, "cannot load %s:%s", dll, name1); return -1; } \
} while (0)

static int resolveWinApi(void) {
    RES(secur32, "secur32.dll", AcceptSecurityContext, "AcceptSecurityContext");
    RES(secur32, "secur32.dll", DeleteSecurityContext, "DeleteSecurityContext");
    RES(secur32, "secur32.dll", EncryptMessage, "EncryptMessage");
    RES(secur32, "secur32.dll", DecryptMessage, "DecryptMessage");
    RES(secur32, "secur32.dll", FreeContextBuffer, "FreeContextBuffer");
    RES2(crypt32, "crypt32.dll", CertDecodeCertificate, "CertDecodeCertificate", "CertDecodeCertificateA");
    RES(crypt32, "crypt32.dll", CertFreeCertificateContext, "CertFreeCertificateContext");
    RES(crypt32, "crypt32.dll", CertSetCertificateContextProperty, "CertSetCertificateContextProperty");
    RES2(crypt32, "crypt32.dll", CryptAcquireContext, "CryptAcquireContextA", "CryptAcquireContext");
    RES2(crypt32, "crypt32.dll", CryptDecodeObject, "CryptDecodeObjectA", "CryptDecodeObject");
    RES(crypt32, "crypt32.dll", CryptImportKey, "CryptImportKey");
    RES2(crypt32, "crypt32.dll", CryptSetKeyProperties, "CryptSetKeyPropertiesA", "CryptSetKeyProperties");
    RES(crypt32, "crypt32.dll", CryptReleaseContext, "CryptReleaseContext");
    RES(crypt32, "crypt32.dll", CryptDestroyKey, "CryptDestroyKey");
    RES(kernel32, "kernel32.dll", LocalFree, "LocalFree");
    RES2(kernel32, "kernel32.dll", GetLastError, "__GetLastError", "GetLastError");
    RES(ws2_32, "ws2_32.dll", recv, "recv");
    RES(ws2_32, "ws2_32.dll", send, "send");
    RES(ws2_32, "ws2_32.dll", WSAGetLastError, "WSAGetLastError");
    return 0;
}

/*
 * One TLS session. pbuf holds plaintext left over from a record that
 * decrypted to more than the caller asked for; rbuf is the record
 * workspace (a record may be delivered in several recvs, and a recv
 * may contain the start of the next record after a complete one).
 * Only the main thread calls tls_read, so rbuf need not be locked;
 * tls_write allocates its own buffers, so concurrent sessions are
 * safe (main thread + sse delivery thread).
 */
struct tls_win {
    CtxtHandle ctx;
    SOCKET sock;
    char pbuf[16384];
    int poff;
    int plen;
    char rbuf[65536];
    int roff;
};

static PCCERT_CONTEXT g_cert;
static HCRYPTPROV g_prov;

static int read_whole_file(const char *path, char *buf, size_t cap, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    *len = fread(buf, 1, cap, f);
    fclose(f);
    return *len < cap ? 0 : -1;
}

static int b64val(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

/*
 * Decode the base64 body of a PEM file: everything after the first
 * newline of the BEGIN marker line, up to the END marker line
 * (whitespace ignored, '=' padding skipped). Returns 0 on success and
 * the DER length in *out_len.
 */
static int pem_to_der(const char *pem, char *out, size_t out_cap, size_t *out_len) {
    const char *begin = strstr(pem, "-----BEGIN");
    const char *end = strstr(pem, "-----END");
    if (!begin || !end || end < begin) return -1;
    const char *p = begin + 10;
    while (p < end && *p != '\n') p++; // skip " CERTIFICATE-----"
    size_t o = 0;
    int bits = 0;
    unsigned acc = 0;
    for (; p < end; p++) {
        int v = b64val(*p);
        if (v < 0) continue;
        acc = (acc << 6) | (unsigned)v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (o + 1 > out_cap) return -1;
            out[o++] = (char)((acc >> bits) & 0xff);
        }
    }
    *out_len = o;
    return 0;
}

static int sendAll(SOCKET s, const char *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        int n = W.send(s, buf + off, (int)(len - off), 0);
        if (n <= 0) {
            if (W.WSAGetLastError() == WSAEINTR) continue;
            return -1;
        }
        off += (size_t)n;
    }
    return 0;
}

/*
 * Read the cert (PEM x509) and key (PEM PKCS#8), import the key into
 * a CRYPTPROV and attach it to the cert context.
 * Returns 0 on success, -1 on error (see tls_last_error).
 */
int tls_init(const char *cert_file, const char *key_file) {
    g_last_err_code = 0;
    if (g_cert) {
        strcpy(g_err, "tls_init called twice");
        return -1;
    }
    ensureWinsock();
    if (resolveWinApi() != 0) return -1;

    static char cert_pem[256 * 1024];
    static char key_pem[256 * 1024];
    static char cert_der[256 * 1024];
    static char key_der[256 * 1024];
    size_t cert_len, key_len, cdlen, kdlen;
    if (read_whole_file(cert_file, cert_pem, sizeof cert_pem, &cert_len) != 0) {
        snprintf(g_err, sizeof g_err, "cannot read %s", cert_file);
        return -1;
    }
    if (read_whole_file(key_file, key_pem, sizeof key_pem, &key_len) != 0) {
        snprintf(g_err, sizeof g_err, "cannot read %s", key_file);
        return -1;
    }
    if (pem_to_der(cert_pem, cert_der, sizeof cert_der, &cdlen) != 0) {
        strcpy(g_err, "cert.pem: no PEM certificate block found");
        return -1;
    }
    if (pem_to_der(key_pem, key_der, sizeof key_der, &kdlen) != 0) {
        strcpy(g_err, "key.pem: no PEM private key block found");
        return -1;
    }

    DerBlob *cd = (DerBlob *)malloc(sizeof(DerBlob) + cdlen);
    if (!cd) {
        strcpy(g_err, "out of memory");
        return -1;
    }
    cd->cbData = (unsigned long)cdlen;
    memcpy(cd->pbData, cert_der, cdlen);

    PCCERT_CONTEXT cert = NULL;
    if (!W.CertDecodeCertificate(CERT_X509_ASN_ENCODING, cd, &cert)) {
        snprintf(g_err, sizeof g_err, "CertDecodeCertificate failed: win32 error %lu", (unsigned long)W.GetLastError());
        goto fail_cd;
    }

    DerBlob *kd = (DerBlob *)malloc(sizeof(DerBlob) + kdlen);
    if (!kd) {
        strcpy(g_err, "out of memory");
        goto fail_cert;
    }
    kd->cbData = (unsigned long)kdlen;
    memcpy(kd->pbData, key_der, kdlen);

    Pkcs8Import p8;
    memset(&p8, 0, sizeof p8);
    p8.cbStruct = sizeof p8;
    p8.pCertContext = cert;
    if (!W.CryptDecodeObject(0 /* X509_ASN_ENCODING */, "PKCS #8", kd, DECODE_FLAG_NOCHECK, &p8)) {
        snprintf(g_err, sizeof g_err,
                 "key.pem is not PKCS#8 - regenerate as \"BEGIN PRIVATE KEY\" (openssl pkcs8 -topk8 -nocrypt): win32 error %lu",
                 (unsigned long)W.GetLastError());
        goto fail_p8;
    }

    HCRYPTPROV prov = 0;
    if (!W.CryptAcquireContext(&prov, NULL, NULL, PROV_RSA_FULL, CRYPT_VERIFYCONTEXT)) {
        snprintf(g_err, sizeof g_err, "CryptAcquireContext failed: win32 error %lu", (unsigned long)W.GetLastError());
        goto fail_prov;
    }

    HCRYPTKEY key = 0;
    if (!W.CryptImportKey(prov, p8.pPrivateKeyBlob, p8.pPrivateKeyBlobLen,
                           p8.pPublicKeyBlob, 0, &key)) {
        snprintf(g_err, sizeof g_err, "CryptImportKey failed (key does not match cert?): win32 error %lu", (unsigned long)W.GetLastError());
        goto fail_key;
    }
    if (!W.CryptSetKeyProperties(key, "feig-tls", AT_KEYEXCHANGE, 0)) {
        snprintf(g_err, sizeof g_err, "CryptSetKeyProperties failed: win32 error %lu", (unsigned long)W.GetLastError());
        goto fail_key;
    }
    if (!W.CertSetCertificateContextProperty(cert, KEY_SPEC, &key, 1 /* CERT_SET_PROPERTY_UNPROTECTED */)) {
        snprintf(g_err, sizeof g_err, "CertSetCertificateContextProperty failed: win32 error %lu", (unsigned long)W.GetLastError());
        goto fail_key;
    }

    if (p8.pPrivateKeyBlob) W.LocalFree(p8.pPrivateKeyBlob);
    if (p8.pPublicKeyBlob) W.LocalFree(p8.pPublicKeyBlob);
    W.LocalFree(kd);
    W.LocalFree(cd);
    g_cert = cert;
    g_prov = prov;
    return 0;

fail_key:
    if (key) W.CryptDestroyKey(key);
fail_prov:
    if (prov) W.CryptReleaseContext(prov, 0);
fail_p8:
    if (p8.pPrivateKeyBlob) W.LocalFree(p8.pPrivateKeyBlob);
    if (p8.pPublicKeyBlob) W.LocalFree(p8.pPublicKeyBlob);
    if (kd) W.LocalFree(kd);
fail_cert:
    if (cert) W.CertFreeCertificateContext(cert);
fail_cd:
    if (cd) W.LocalFree(cd);
    return -1;
}

static void sessionFail(struct tls_win *h) {
    if (h->ctx.ulContextHandle) W.DeleteSecurityContext(&h->ctx);
    free(h);
}

/*
 * Run the server handshake on an accepted, blocking socket.
 * Returns the session handle on success, NULL on error (see
 * tls_last_error). The client sends one record per flight
 * (ClientHello, then Finished), so each round recv's until a complete
 * TLS record (5-byte header + payload) is buffered, then hands it to
 * AcceptSecurityContext.
 */
void *tls_accept(void *sock) {
    g_last_err_code = 0;
    if (!g_cert) {
        strcpy(g_err, "tls_init not called");
        return NULL;
    }
    SOCKET s = (SOCKET)sock;
    struct tls_win *h = (struct tls_win *)malloc(sizeof *h);
    if (!h) {
        strcpy(g_err, "out of memory");
        return NULL;
    }
    memset(h, 0, sizeof *h);
    h->sock = s;

    SChannelCred cred;
    memset(&cred, 0, sizeof cred);
    cred.dwVersion = SCHANNEL_CRED_VERSION;
    cred.h_CERT = g_cert;

    CtxtHandle *prev_ctx = NULL;
    for (int round = 0; round < 10; round++) {
        char raw[16384];
        int total = 0;
        for (;;) {
            if (total >= 5) {
                int reclen = ((unsigned char)raw[3] << 8) | (unsigned char)raw[4];
                if (total >= 5 + reclen) break; // complete record
            }
            if (total >= (int)sizeof raw) {
                snprintf(g_err, sizeof g_err, "handshake record larger than 16KB");
                sessionFail(h);
                return NULL;
            }
            int n = W.recv(s, raw + total, sizeof raw - (size_t)total, 0);
            if (n == 0) {
                strcpy(g_err, "peer closed connection during handshake");
                sessionFail(h);
                return NULL;
            }
            if (n < 0) {
                snprintf(g_err, sizeof g_err, "handshake recv failed: win32 error %lu", (unsigned long)W.WSAGetLastError());
                sessionFail(h);
                return NULL;
            }
            total += n;
        }

        SecBuffer in_buf = { SECBUFFER_DATA, (unsigned long)total, raw };
        SecBufferDesc in_desc = { SECBUFFER_VERSION, 1, &in_buf };
        SecBuffer out_data = { SECBUFFER_DATA, 0, NULL };
        SecBuffer out_empty1 = { SECBUFFER_EMPTY, 0, NULL };
        SecBuffer out_empty2 = { SECBUFFER_EMPTY, 0, NULL };
        SecBuffer out_empty3 = { SECBUFFER_EMPTY, 0, NULL };
        SecBuffer out_bufs[4] = { out_data, out_empty1, out_empty2, out_empty3 };
        SecBufferDesc out_desc = { SECBUFFER_VERSION, 4, out_bufs };
        unsigned long attrs = 0;

        /*
         * AcceptSecurityContext(pCredential, pPreviousContext, pInput,
         *   dwFlags, psInterface, pContext, pOutput, pAttrs, pExpiry)
         */
        int rc = W.AcceptSecurityContext(&cred, prev_ctx, &in_desc, LOCAL_WS_IP_ADDRESS,
                                         NULL, &h->ctx, &out_desc, &attrs, NULL);

        if (rc == SEC_I_CONTINUE_NEEDED) {
            for (int k = 0; k < 4; k++) {
                if (out_bufs[k].cbBuffer > 0 &&
                    sendAll(s, (char *)out_bufs[k].pvBuffer, out_bufs[k].cbBuffer) != 0) {
                    snprintf(g_err, sizeof g_err, "handshake send failed: win32 error %lu", (unsigned long)W.WSAGetLastError());
                    W.FreeContextBuffer(&out_desc);
                    sessionFail(h);
                    return NULL;
                }
            }
            W.FreeContextBuffer(&out_desc);
            prev_ctx = &h->ctx;
            continue;
        }
        if (rc == SEC_E_OK) {
            // normally empty; send anything pending before returning
            for (int k = 0; k < 4; k++) {
                if (out_bufs[k].cbBuffer > 0 &&
                    sendAll(s, (char *)out_bufs[k].pvBuffer, out_bufs[k].cbBuffer) != 0) {
                    snprintf(g_err, sizeof g_err, "handshake send failed: win32 error %lu", (unsigned long)W.WSAGetLastError());
                    W.FreeContextBuffer(&out_desc);
                    sessionFail(h);
                    return NULL;
                }
            }
            W.FreeContextBuffer(&out_desc);
            return h;
        }
        g_last_err_code = rc;
        snprintf(g_err, sizeof g_err, "AcceptSecurityContext failed: sec status 0x%08lx, win32 error %lu",
                 (unsigned long)rc, (unsigned long)W.WSAGetLastError());
        W.FreeContextBuffer(&out_desc);
        sessionFail(h);
        return NULL;
    }
    strcpy(g_err, "handshake did not complete in 10 round trips");
    sessionFail(h);
    return NULL;
}

/*
 * Read over the TLS stream. Returns >0 for bytes transferred,
 * 0 for a clean peer close, negative on error. One TLS record at a
 * time: the record header (bytes 0-4) gives the payload length, the
 * record is decrypted in place, and any bytes after it (the start of
 * the next record) are kept in rbuf for the next call.
 */
int tls_read(void *ssl, void *buf, int len) {
    struct tls_win *h = (struct tls_win *)ssl;
    if (!h) {
        strcpy(g_err, "tls_read with null session");
        return -1;
    }
    g_last_err_code = 0;

    // plaintext left over from a previous record that was bigger than
    // the read request
    if (h->poff < h->plen) {
        int n = h->plen - h->poff;
        if (n > len) n = len;
        memcpy(buf, h->pbuf + h->poff, (size_t)n);
        h->poff += n;
        return n;
    }

    // wait until a complete record is in rbuf
    for (;;) {
        if (h->roff >= 5) {
            int reclen = ((unsigned char)h->rbuf[3] << 8) | (unsigned char)h->rbuf[4];
            if (h->roff >= 5 + reclen) break;
        }
        if (h->roff >= (int)sizeof h->rbuf) {
            strcpy(g_err, "tls record larger than 64KB");
            return -1;
        }
        int n = W.recv(h->sock, h->rbuf + h->roff, sizeof h->rbuf - (size_t)h->roff, 0);
        if (n == 0) return 0; // clean peer close
        if (n < 0) {
            g_last_err_code = W.WSAGetLastError();
            snprintf(g_err, sizeof g_err, "recv failed: win32 error %lu", (unsigned long)W.WSAGetLastError());
            return -1;
        }
        h->roff += n;
    }
    int reclen = ((unsigned char)h->rbuf[3] << 8) | (unsigned char)h->rbuf[4];
    int skip = 5 + reclen;

    SecBuffer data = { SECBUFFER_DATA, (unsigned long)skip, h->rbuf };
    SecBufferDesc desc = { SECBUFFER_VERSION, 1, &data };
    int rc = W.DecryptMessage(&desc, NULL, 0, 0);
    if (rc != SEC_E_OK) {
        g_last_err_code = rc;
        snprintf(g_err, sizeof g_err, "DecryptMessage failed: sec status 0x%08lx", (unsigned long)rc);
        h->roff = 0; // the record is undecryptable; the session is broken
        return -1;
    }
    int plain = (int)data.cbBuffer;
    if (plain > len) {
        memcpy(buf, h->rbuf, (size_t)len);
        memcpy(h->pbuf, h->rbuf + len, (size_t)(plain - len));
        h->poff = 0;
        h->plen = plain - len;
    } else {
        memcpy(buf, h->rbuf, (size_t)plain);
    }
    // drop the decrypted record, keep anything after it
    memmove(h->rbuf, h->rbuf + skip, (size_t)(h->roff - skip));
    h->roff -= skip;
    return plain > len ? len : plain;
}

int tls_write(void *ssl, const void *buf, int len) {
    struct tls_win *h = (struct tls_win *)ssl;
    if (!h) {
        strcpy(g_err, "tls_write with null session");
        return -1;
    }
    if (len <= 0) return 0;
    g_last_err_code = 0;
    // per-call buffers (not static): two sessions may be written at the
    // same time (main thread + sse delivery thread)
    char *enc = (char *)malloc((size_t)len + 4096);
    if (!enc) {
        strcpy(g_err, "out of memory");
        return -1;
    }
    SecBuffer plain = { SECBUFFER_DATA, (unsigned long)len, (void *)buf };
    SecBuffer trailer = { SECBUFFER_EMPTY, 0, NULL };
    SecBuffer out = { SECBUFFER_DATA, 4096, enc };
    SecBuffer bufs[3] = { plain, trailer, out };
    SecBufferDesc desc = { SECBUFFER_VERSION, 3, bufs };
    int rc = W.EncryptMessage(&desc, 0, NULL, 0);
    if (rc != SEC_E_OK) {
        g_last_err_code = rc;
        snprintf(g_err, sizeof g_err, "EncryptMessage failed: sec status 0x%08lx", (unsigned long)rc);
        free(enc);
        return -1;
    }
    // on return: out = the encrypted record (header + ciphertext),
    // trailer = the MAC, which must be appended when sending
    if (out.cbBuffer > 0 && sendAll(h->sock, (char *)out.pvBuffer, out.cbBuffer) != 0) {
        snprintf(g_err, sizeof g_err, "send failed: win32 error %lu", (unsigned long)W.WSAGetLastError());
        free(enc);
        return -1;
    }
    if (trailer.cbBuffer > 0 && sendAll(h->sock, (char *)trailer.pvBuffer, trailer.cbBuffer) != 0) {
        snprintf(g_err, sizeof g_err, "send failed: win32 error %lu", (unsigned long)W.WSAGetLastError());
        free(enc);
        return -1;
    }
    free(enc);
    return len;
}

void tls_free(void *ssl) {
    struct tls_win *h = (struct tls_win *)ssl;
    if (!h) return;
    if (h->ctx.ulContextHandle) W.DeleteSecurityContext(&h->ctx);
    free(h);
}

int feig_close_socket(void *sock) {
    static int (*pclosesocket)(SOCKET) = 0;
    ensureWinsock();
    if (!pclosesocket) {
        void *m = LoadLibraryA("ws2_32.dll");
        if (m) pclosesocket = (int (*)(SOCKET))GetProcAddress(m, "closesocket");
    }
    if (!pclosesocket) return -1;
    return pclosesocket((SOCKET)sock);
}

int feig_sock_write(void *sock, const void *buf, int len) {
    static int (*psend)(SOCKET, const void *, int, int) = 0;
    static unsigned long (*p_ws_errno)(void) = 0;
    ensureWinsock();
    if (!psend) {
        void *m = LoadLibraryA("ws2_32.dll");
        if (!m) return -1;
        psend = (int (*)(SOCKET, const void *, int, int))GetProcAddress(m, "send");
        if (!psend) return -1;
        p_ws_errno = (unsigned long (*)(void))GetProcAddress(m, "WSAGetLastError");
    }
    int rc = psend((SOCKET)sock, buf, len, 0);
    /*
     * One-shot diagnostic for the windows /events/ delivery bug: the
     * sock value reveals whether zig's socket handle is the SOCKET
     * value itself or a pointer to it, and err the winsock state
     * (10093 = not initialized, 10035 = would block, 10038 = not a
     * socket, 10053/10054 = closed/reset by peer).
     */
    static int diag_done = 0;
    if (!diag_done) {
        diag_done = 1;
        if (rc >= 0) {
            fprintf(stderr, "feig-sse: first write sock=0x%llx len=%d rc=%d\n",
                    (unsigned long long)(uintptr_t)sock, len, rc);
        } else {
            fprintf(stderr, "feig-sse: first write sock=0x%llx len=%d rc=%d err=%lu\n",
                    (unsigned long long)(uintptr_t)sock, len, rc, p_ws_errno ? p_ws_errno() : 0);
        }
        fflush(stderr);
    }
    return rc;
}

int feig_get_my_ip(char *buf, int len) {
    static int (*p_socket)(int, int, int) = 0;
    static int (*p_connect)(SOCKET, const void *, int) = 0;
    static int (*p_getsockname)(SOCKET, void *, int *) = 0;
    static int (*p_close)(SOCKET) = 0;
    if (!p_socket) {
        void *m = LoadLibraryA("ws2_32.dll");
        if (!m) return -1;
        p_socket = (int (*)(int, int, int))GetProcAddress(m, "socket");
        p_connect = (int (*)(SOCKET, const void *, int))GetProcAddress(m, "connect");
        p_getsockname = (int (*)(SOCKET, void *, int *))GetProcAddress(m, "getsockname");
        p_close = (int (*)(SOCKET))GetProcAddress(m, "closesocket");
        if (!p_socket || !p_connect || !p_getsockname || !p_close) return -1;
    }
    ensureWinsock();
    SOCKET s = p_socket(2 /*AF_INET*/, 2 /*SOCK_DGRAM*/, 0);
    if ((int)s == -1) return -1;
    struct feig_sockaddr_in sa;
    memset(&sa, 0, sizeof sa);
    sa.family = 2; /* AF_INET */
    sa.addr = 0x01010101; /* 1.1.1.1, network order (palindrome: endian-safe) */
    if (p_connect(s, &sa, sizeof sa) != 0) {
        p_close(s);
        return -1;
    }
    struct feig_sockaddr_in local;
    int llen = (int)sizeof local;
    int rc = p_getsockname(s, &local, &llen);
    p_close(s);
    if (rc != 0) return -1;
    unsigned char *b = (unsigned char *)&local.addr;
    return snprintf(buf, (size_t)len, "%u.%u.%u.%u", b[0], b[1], b[2], b[3]);
}

#endif

const char *tls_last_error(void) {
    return g_err;
}

int tls_last_err_code(void) {
    return g_last_err_code;
}
