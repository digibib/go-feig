# Install

You will need Feig drivers for your system/architecture installed for either USB, TCP or Serial devices

For compiling server you'll need at least feisc and fetcp drivers, as well as header files installed in ./drivers

## linux GNU x86 or x64 system

linux SDK with feig shared object files (builds on libusb)
(current: ID_ISC.SDK.Linux-V4.9.2.zip)

find runtime libraries for architecture and install, e.g: 64bit:

```
cd ID_ISC.SDK.Linux-V4.9.2/sw-run/x64/
sudo bash ./install-libs.sh /lib/x86_64-linux-gnu/
```

## USB Permissions

For usb device, create an udev rule to grant proper permissions unless root
Get usb udev actions
```
udevadm monitor --kernel --property --subsystem-match=usb
```
Write rule using product
```
/etc/udev/rules.d/41-feig.rules
# Rule for Feig USB reader
SUBSYSTEMS=="usb", ACTION=="add", ATTRS{idVendor}=="0ab1", ATTRS{idProduct}=="0002", MODE:="0666", GROUP="users", SYMLINK+="feig_usb"
```

## reload udev rules
```
sudo udevadm control --reload-rules && sudo udevadm trigger
```

## systemd service

sudo cp docs/feiging.service /etc/systemd/system
sudo systemctl enable feiging && sudo systemctl start feiging

## TLS

Cross origin requests may stop in browser if server is not serving TLS

    openssl req -newkey rsa:2048 -new -nodes -x509 -days 3650 -keyout key.pem -out cert.pem

## frontend dev

(DEV): install node
```
curl -sL https://deb.nodesource.com/setup_10.x -o nodesource_setup.sh
sudo bash nodesource_setup.sh
sudo apt-get install -y nodejs
```
