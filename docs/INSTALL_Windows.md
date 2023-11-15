# Install Windows

## Compile from linux for x64 system

```sudo apt-get install gcc-multilib gcc-mingw-w64```

```
GOOS=windows GOARCH=amd64 CGO_ENABLED=1 CC=x86_64-w64-mingw32-gcc CXX=x86_64-w64-mingw32-g++ go build -o feiging.exe feiging_usb.go eshub.go
```

## Install

Install Visual C++ runtime (else: MSVCP120.dll Missing)

    https://www.microsoft.com/en-us/download/details.aspx?id=14632

Copy runtime, drivers and html to wanted folder

    feisc.dll
    feusb.dll
    fetcp.dll
    feig.exe
