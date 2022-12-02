# DOCS:
	Python example: https://github.com/NuclearDog/feig-obid
	SDK:     https://www.st.com/content/ccc/resource/technical/document/application_note/5f/3c/69/4a/9a/1e/45/35/CD00275180.pdf/files/CD00275180.pdf/jcr:content/translations/en.CD00275180.pdf
	FEUSB.h: http://docs.ros.org/hydro/api/rfid_drivers/html/feusb_8h.html#a51a74a7b298516435a9e76a3dd2931a0

# C Methods:
	FEUSB_ClearScanList() : This function re-initializes the USB detection process by clearing the list of scanned
	FEUSB_Scan(int iScanOpt, FEUSB_SCANSEARCH *pSearchOpt) :
	FEUSB_GetScanListSize() : This function retrieves the number of detected readers.
	FEUSB_GetScanListPara() : This function gives access to all the detected reader information.
	FEUSB_OpenDevice(C.long(id)): This function opens a communication channel between a USB FEIG reader and the
	FEUSB dll, and assigns a handle to this channel.
	FEISC_NewReader(C.long(id)) : open FEISC comm

	int DLL_EXT_FUNC 	FEUSB_AddEventHandler (int iDevHnd, FEUSB_EVENT_INIT *pInit)
	void DLL_EXT_FUNC 	FEUSB_ClearScanList ()
	int DLL_EXT_FUNC 	FEUSB_CloseDevice (int iDevHnd)
	int DLL_EXT_FUNC 	FEUSB_DelEventHandler (int iDevHnd, FEUSB_EVENT_INIT *pInit)
	int DLL_EXT_FUNC 	FEUSB_GetDeviceHnd (long nDeviceID)
	int DLL_EXT_FUNC 	FEUSB_GetDeviceList (int iDevHnd)
	int DLL_EXT_FUNC 	FEUSB_GetDevicePara (int iDevHnd, char *cPara, char *cValue)
	void DLL_EXT_FUNC 	FEUSB_GetDLLVersion (char *cVersion)
	int DLL_EXT_FUNC 	FEUSB_GetDrvVersion (char *cVersion)
	int DLL_EXT_FUNC 	FEUSB_GetErrorText (int iError, char *cText)
	int DLL_EXT_FUNC 	FEUSB_GetLastError (int iDevHnd, int *iErrorCode, char *cErrorText)
	int DLL_EXT_FUNC 	FEUSB_GetScanListPara (int iIndex, char *cParaID, char *cValue)
	int DLL_EXT_FUNC 	FEUSB_GetScanListSize ()
	int DLL_EXT_FUNC 	FEUSB_IsDevicePresent (int iDevHnd)
	int DLL_EXT_FUNC 	FEUSB_OpenDevice (long nDeviceID)
	int DLL_EXT_FUNC 	FEUSB_Receive (int iDevHnd, char *cInterface, unsigned char *cRecData, int iRecLen)
	int DLL_EXT_FUNC 	FEUSB_Scan (int iScanOpt, FEUSB_SCANSEARCH *pSearchOpt)
	int DLL_EXT_FUNC 	FEUSB_ScanAndOpen (int iScanOpt, FEUSB_SCANSEARCH *pSearchOpt)
	int DLL_EXT_FUNC 	FEUSB_SetDevicePara (int iDevHnd, char *cPara, char *cValue)
	int DLL_EXT_FUNC 	FEUSB_Transceive (int iDevHnd, char *cInterface, int iDir, unsigned char *cSendData, int iSendLen, unsigned char *cRecData, int iRecLen)
	int DLL_EXT_FUNC 	FEUSB_Transmit (int iDevHnd, char *cInterface, unsigned char *cSendData, int iSendLen)

# CGO TYPE CONVERSIONS:

	char -->  C.char -->  byte
	signed char -->  C.schar -->  int8
	unsigned char -->  C.uchar -->  uint8
	short int -->  C.short -->  int16
	short unsigned int -->  C.ushort -->  uint16
	int -->  C.int -->  int
	unsigned int -->  C.uint -->  uint32
	long int -->  C.long -->  int32 or int64
	long unsigned int -->  C.ulong -->  uint32 or uint64
	long long int -->  C.longlong -->  int64
	long long unsigned int -->  C.ulonglong -->  uint64
	float -->  C.float -->  float32
	double -->  C.double -->  float64
	wchar_t -->  C.wchar_t  -->
	void * -> unsafe.Pointer

## THREE MAIN POINTERS:
	- index of reader : used in FEUSB PARAMS
	- iPortHandle : int pointer to FEUSB handle
	- iReaderHandle : int handle of reader - used by FEISC

