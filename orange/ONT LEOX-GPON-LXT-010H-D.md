---
tags:
  - nbux/orange
---
# ONT LEOX-GPON-LXT-010H-D


Version 20250110
## Links

[http://xbest.pl/index.php?p5117,ont-gpon-lxt-010h-d-leox-1x2-5ge-1xgpon-sc-apc](http://xbest.pl/index.php?p5117,ont-gpon-lxt-010h-d-leox-1x2-5ge-1xgpon-sc-apc)

[https://lafibre.info/remplacer-livebox/mise-en-route-leox-lxt-010h-d/252/](https://lafibre.info/remplacer-livebox/mise-en-route-leox-lxt-010h-d/252/)

[https://lafibre.info/remplacer-livebox/trouver-la-valeur-hw_hwver-pour-leox-lxt-01g-d-lxt-010h-d/](https://lafibre.info/remplacer-livebox/trouver-la-valeur-hw_hwver-pour-leox-lxt-01g-d-lxt-010h-d/)

[https://wiki-archive.opencord.org/attachments/1966449/2557137.pdf](https://wiki-archive.opencord.org/attachments/1966449/2557137.pdf)

Manufacturer : marcinkuczera https://lafibre.info/profile/marcinkuczera/ (marcin.kuczera at leolabs.pl)


## Defaults

IP: 192.168.100.1
login/passwd: leox / leolabs_7
telnet and HTTP web interface

## Setting Params

Note : Some OLT (Huawei) seems to be very restrictives. 
**Firstly, try to skip some optional settings (HW_HWVER, OMCC, HW_CWMP)**

Secondly, get all default values
It is a best practice to read default values before modify them...
```
flash all
flash all | grep GPON_SN
flash all | grep PON_VENDOR
```


1. set the mandatory params
You have to set GPON serial and vendor ID 
```
# flash set GPON_SN HWTCxxxxxxxx
GPON_SN=HWTCxxxxxxxx
# flash set PON_VENDOR_ID HWTC
PON_VENDOR_ID=HWTC
```

Then, on the WEB interface, you can check the PON Status : 
```
Vendor Name     LeoLabs
Part Number     LXT-010H-D
Temperature     75.074219 C
Voltage 3.401500 V
Tx Power        1.076726 dBm
Rx Power        -17.077437 dBm
Bias Current    0.000000 mA
GPON Status
ONU State       O5
ONU ID  2143923176
LOID Status     Initial Status
```


If you do NOT have O5 for the ONU State, try the following commands and check again the web page...
Some Huawei OLT (ISP side) are very restrictive, that's why the following params could be required.

2. set hardware version (should not be required on Huawei OLT)
**It is better to SKIP this to avoid unexpected reboot (by Orange when trying to remote upgrade firmware).**
```
# flash set HW_HWVER HWTCA240FA
HW_HWVER=HWTCA240FA
```

Here are some correct ONT hardware versions :

| Version          | Hardware          |
| ---------------- | ----------------- |
| Livebox7         | SMBS SMBSXLB7400  |
| Livebox6         | SMBS SMBSSGLB6107 |
| Huawei HG8010Hv6 | HWTC HWTCA240FA   |


Note: If you encounter some DHCP issues and everything seems right, try to change the HWVER without modifying SERIAL number. For example, Huawei ONT serial number with a Livebox6 HWVER.

3. OMCC compliance
**This param seems to be important on some OLT. Try to skip this, but use if you encounter issues...** 
See [https://wiki-archive.opencord.org/attachments/1966449/2557137.pdf](https://wiki-archive.opencord.org/attachments/1966449/2557137.pdf) (cf. ONU-G ME #256, ONU2-G ME #257, Software Image ME #7)
80 : (default) do not work well
B0 : (HG8010H) do not work well too
A0 : everything is OK
ONU-G / ME #256
ONU2-G / ME #257
Software image / ME #7

Note : 160d == AOh

```
# flash set OMCC_VER 160
OMCC_VER=160
# flash set OMCI_SW_VER1 HWTCA31xxxx
OMCI_SW_VER1=HWTCA31xxxx
# flash set OMCI_SW_VER2 HWTCA31xxxx
OMCI_SW_VER2=HWTCA31xxxx
```

4. Manufacturer
```
# flash set HW_CWMP_MANUFACTURER HUAWEI
HW_CWMP_MANUFACTURER=HUAWEI
# flash set HW_CWMP_PRODUCTCLASS HG8010H
HW_CWMP_PRODUCTCLASS=HG8010H
```

5. OLT compat (customized, will also unlock advanced params on web interface)
```
# flash set OMCI_OLT_MODE 3
OMCI_OLT_MODE=3
```

Possible values are :
```
<option value="0">Default Mode</option>
<option value="1">Huawei OLT Mode</option>
<option value="2">ZTE OLT Mode</option>
<option value="3" selected="">Customized Mode</option>
```


## Others commands


```
omcicli mib get all
flash all
flash all | grep xxx
```

## Firmware upgrade 

Before upgrade, make a backup of files rtl8290b.data and europa.data from /var/config folder. These files include optical calibration of your ONT’s laser, if you accidentally delete or ruin them, your ONT will be unusable.

You must also rollback the HW_HWVER to 'LXT-010H-D'.
```
flash set HW_HWVER LXT-010H-D
```

- Versions :
Original version is V3.3.2L6
Last known version (01/2023) is V3.3.2L7

- On the router / server :
```
netcat -l  -p 10000  > europa.data
```
- On the LEOX :
```
busybox nc 192.168.x.y 10000 < /var/config/europa.data
```
- Do the same for /var/config/rtl8290b.data

Then, upgrade firmware via web interface...
Do not forget to re-apply the good value if it was previoulsy required (flash set HW_HWVER HWTCA240FA).


## Notes

### OLT infos

```
get ME#131
omcicli mib get 131 # or try : omcicli mib get 131,0 ; omcicli mib get all
```

```
XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX  
OltG  
XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX  
=================================  
EntityId: 0x00  
OltVendorId: HWTC  
EquipId:  
Version: 10  
ToDInfo:  
        Sequence number of GEM superframe: 0x93b6c40  
        Timestamp: secs 1674856035, nanosecs 842287992  
=================================
```

If you get an hexa string, then convert to ascii (https://www.rapidtables.com/convert/number/hex-to-ascii.html)
-> ALCL=Alcatel, HWTC=Huawei

You could also try the following commands :
```
omcicli -c OR omci_pipe.sh
```
"help" should work, there is "omci_pipe.sh mda" to dump all MIBs


## Logging

### Dump logfile

dump OMCI log:
```
flash set OMCI_LOGFILE 3   # if error, try cfgmib set OMCI_LOGFILE 3
reboot 
```

and after is it provisioned by OLT:  
```  
cat /var/tmp/omcilog.par  
```

Remember to restore this after this operation:
```
flash set OMCI_LOGFILE 0
```


### Redirect logs

To redirect logs to /tmp/omci.log instead of /dev/console, update /etc/init.d/omcid.sh
before:
```
${OMCID_BIN} -d3 -p$mib_file  -o$omcc_version -i$omci_iop_mask ${lct} -l/tmp/log/debug > /dev/console 2> /dev/console &
```
after:
```
${OMCID_BIN} -d1 -p$mib_file  -o$omcc_version -i$omci_iop_mask ${lct} -l/tmp/omci.log > /dev/console 2> /dev/console &
```


