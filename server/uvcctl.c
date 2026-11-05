// Minimal UVC control get/set for the DJI Osmo Pocket 3 via IOKit (no device open needed for EP0 requests).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/IOCFPlugIn.h>

static IOUSBDeviceInterface **open_dev(void) {
    CFMutableDictionaryRef m = IOServiceMatching("IOUSBHostDevice");
    int vid = 0x2ca3, pid = 0x0023;
    CFDictionarySetValue(m, CFSTR("idVendor"), CFNumberCreate(NULL, kCFNumberIntType, &vid));
    CFDictionarySetValue(m, CFSTR("idProduct"), CFNumberCreate(NULL, kCFNumberIntType, &pid));
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, m);
    if (!svc) { fprintf(stderr, "camera not found\n"); exit(2); }
    IOCFPlugInInterface **plug; SInt32 score;
    if (IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score)) {
        fprintf(stderr, "plugin failed\n"); exit(2);
    }
    IOUSBDeviceInterface **dev;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
    (*plug)->Release(plug);
    return dev;
}

// usage: uvcctl get <req hex> <entity> <selector> <len>
//        uvcctl set <entity> <selector> <hexbytes>
int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: uvcctl get REQ ENTITY SEL LEN | set ENTITY SEL HEX\n"); return 1; }
    IOUSBDeviceInterface **dev = open_dev();
    IOUSBDevRequest r; unsigned char buf[64] = {0};
    if (!strcmp(argv[1], "get") && argc == 6) {
        r.bmRequestType = 0xA1; r.bRequest = strtol(argv[2], 0, 16);
        r.wValue = atoi(argv[4]) << 8; r.wIndex = atoi(argv[3]) << 8; r.wLength = atoi(argv[5]);
    } else if (!strcmp(argv[1], "set") && argc == 5) {
        size_t n = strlen(argv[4]) / 2;
        for (size_t i = 0; i < n; i++) sscanf(argv[4] + 2 * i, "%2hhx", &buf[i]);
        r.bmRequestType = 0x21; r.bRequest = 0x01;
        r.wValue = atoi(argv[3]) << 8; r.wIndex = atoi(argv[2]) << 8; r.wLength = n;
    } else { fprintf(stderr, "bad args\n"); return 1; }
    r.pData = buf;
    IOReturn kr = (*dev)->DeviceRequest(dev, &r);
    if (kr) { printf("ERR 0x%08x\n", kr); return 3; }
    for (int i = 0; i < r.wLenDone; i++) printf("%02x", buf[i]);
    printf("\n");
    return 0;
}
