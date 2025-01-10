---
tags:
  - nbux/orange
---
# ONU GPON-ONU-34-20BI

Version 20241220
## Links 
https://www.fs.com/fr/products/133619.html
https://lafibre.info/remplacer-livebox/guide-de-connexion-fibre-directement-sur-un-routeur-voire-meme-en-2gbps/
https://hack-gpon.github.io/ont-fs-com-gpon-onu-stick-with-mac/
https://hack-gpon.github.io/ont-fs-com-gpon-onu-stick-with-mac/#enabling-data_1g_8q_us1280_ds512ini-omci-mib-file-for-2500-mbps-profiles


## Mikrotik RouterOS

To be able to flash the WAS-110 inside a Mikrotik switch without to have to connect the fiber (and power-on the ONU), just disable rx-loss on the port :

```
/interface ethernet set [ find default-name=sfp-sfpplusX ] sfp-ignore-rx-los=yes
```


To be sure to set the right speed on ONU switch/router SFP port:
```
/interface/ethernet set auto-negotiation=no sfp-sfpplusX set speed=2.5Gbps sfp-sfpplusX
```


## Defaults params

IP : 192.168.1.10
login/passwd : ONTUSER / 7sp!lwUBz1
ssh only

## Base config

- connect via SSH (ssh client must be in the same network than ONU)
note : -oHostKeyAlgorithms=+ssh-dss do NOT work any more since openssh v9.9
```
ssh -o KexAlgorithms=+diffie-hellman-group14-sha1 -oHostKeyAlgorithms=+ssh-rsa <onu_ip_addr> -l ONTUSER
/system/ssh address=192.168.1.10 user=ONTUSER (from RouterOS)
login: ONTUSER
passwd: 7sp!lwUBz1
```

- change SN and VendorID (example for Huawei)
```
fw_printenv
sfp_i2c -i8 -s "HWTC305xxx" # SN for ISP OLT side - MANDATORY
sfp_i2c -i3 -s "HWTC305xxx" # SN (Vendor Serial) for router side
set_serial_number HWTC305xxx # again to be consistent
sfp_i2c -i7 -s "HWTC"  # OR sfp_i2c -I -s "HWTC"
sfp_i2c -g # OR fw_printenv | grep nSerial
fw_setenv sgmii_mode 5 # force 2500BaseX
reboot
```

- verify/set operating mode SGMII
```
fw_printenv sgmii_mode
# if not defined, then execute
fw_setenv sgmii_mode 5
fw_printenv sgmii_mode
```

Values (for sgmii_mode and link_status)  Speed
3       1 Gbps / SGMII with auto-neg on
4       1 Gbps / SGMII with auto-neg off
5       2.5 Gbps / HSGMII with auto-neg on
The firmware already should have the value 5 by default and it is generally not necessary to change it.

## Check link status

- current status must be "O5"
```
onu ploamsg # curr_state=O5
gtop # press c ; press v
```

- check logs (see redirect logs section below)
omci.log  ; /var/log/debug
grep --binary-files=text -i scom omci.log

- check speed (download / upload)
use iperf to do this...
for tx/rx value check on switch port directly

## Logfile 

To redirect logs to /tmp/omci.log instead of /dev/console, update /etc/init.d/omcid.sh

before:
```
${OMCID_BIN} -d3 -p$mib_file  -o$omcc_version -i$omci_iop_mask ${lct} -l/tmp/log/debug > /dev/console 2> /dev/console &
```
after:
```
${OMCID_BIN} -d1 -p$mib_file  -o$omcc_version -i$omci_iop_mask ${lct} -l/tmp/omci.log > /dev/console 2> /dev/console &
```


## Change IP

```
fw_printenv
fw_setenv ipaddr 192.168.4.x
fw_setenv gatewayip 192.168.4.xxx
fw_printenv
```



## Troubleshooting

### VLAN issues

Check if you got Orange VLAN  (gtop ; press C ; press Y) or (gtop ; press C ; press V) 
it should be like this :
```
GPE VLAN treatment
Name:        ONU_GPE_VLAN_TREATMENT_TABLE
ID:          43
;;;;tagb;tagb;tagb;taga;taga;taga
no;inner not generate;outer not generate;discard enable;tpid;vid;treatment;tpid;vid;treatment
0;1;1; ;4;   1; 1;4;    ;15
1;1;1; ; ; 851; 9; ;    ;15
2;1;1; ; ; 840; 9; ;    ;15
3;1;1; ; ; 838; 9; ;    ;15
4;1;1; ; ; 835; 9; ;    ;15
5;1;1; ; ; 832; 9; ;    ;15
6;1; ; ; ;    ;15; ;    ;15
7; ; ; ; ;    ;15; ;    ;15
64;1;1; ; ;    ;15; ;    ;15
65;1;1; ;6; 851; 9; ;    ;15
66;1;1; ;6; 840; 9; ;    ;15
67;1;1; ;6; 838; 9; ;    ;15
68;1;1; ;6; 835; 9; ;    ;15
69;1;1; ;6; 832; 9; ;    ;15
70;1; ; ; ;    ;15; ;    ;15
71; ; ; ; ;    ;15; ;    ;15
128;1;1; ; ;    ;15; ;    ;15
129;1;1; ; ;    ;15; ;    ;15
130; ;1; ; ;    ;15; ;    ;15
```

- In some case, it is not the VLAN 832, but instead, you will see VLAN 2800
But this VLAN 2800 is translated to 832 by the ONU/ONT (check ONU_GPE_VLAN_RULE_TABLE or/and ONU_GPE_VLAN_TREATMENT_TABLE). To see what was requested by the OLT use `omci_pipe.sh meg 171 1`or `omci_pipe.sh meg 171 0` and decode the table with https://hack-gpon.org/gpon-omci-vlan-parser/.
```
GPE VLAN  
  
Name:        ONU_GPE_VLAN_TABLE  
ID:          18  
no;pcp;dei;vid;vlan_meter_enable;vlan_meter_id;end  
32; ; ;2800; ; ;   
33; ; ; ; ; ;1  
36; ; ;835; ; ;   
37; ; ;852; ; ;   
38; ; ;2800; ; ;   
39; ; ; ; ; ;1  
40; ; ;835; ; ;   
41; ; ; ; ; ;1  
44; ; ;852; ; ;   
45; ; ; ; ; ;1
```

- check OLT vendor
Some OLT (ISP side) check Hardware Version from ONT (HWTC OLT do not check this, it is not necessary to change anything).
```
# omci_pipe.sh meg 131 0
Class ID    = 131 (OLT-G)
Instance ID = 0
Upload      = yes
Alarms      = -
-------------------------------------------------------------------------------
 0 OLT vendor id                 4b STR  RW-----P---
   0x48 0x57 0x54 0x43
   HWTC
-------------------------------------------------------------------------------
 1 Equipment id                 20b STR  RW-----P---
   0x20 0x20 0x20 0x20 0x20 0x20 0x20 0x20 0x20 0x20 0x20 0x20 0x20 0x20 0x20 0x20 0x20 0x20 0x20 0x20

-------------------------------------------------------------------------------
 2 Version                      14b STR  RW-----P---
   0x31 0x30 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00
   10\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00
-------------------------------------------------------------------------------
 3 Time of day information      14b STR  RW--O--P---
   0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00
   \x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00
-------------------------------------------------------------------------------
R - Readable          O - Not supported (optional)
W - Writable          E - Excluded from MIB upload (template)
S - set-by-create     T - Table
A - Send AVC          V - Volatile
U - No upload         P - No swap
N - Not suported      Y - Partly supported
N - No swap

errorcode=0
```

You could also check in logfile omci.log (need to be enabled before - see section) 
```
# cat omci.log | grep vendor  
[omcid] 13:58:14 CORE  PRN: 131@0 set OLT vendor id             = 20 20 20 20 "    "  
[omcid] 13:58:29 CORE  PRN: 131@0 set OLT vendor id             = 41 4c 43 4c "**ALC**L"
```

The Hardware Version is defined in mibs file (/etc/mibs). You have to spoof a correct Hardware Version to work correctly with Alcatel/Nokia OLT.
For example, here are some correct ONT Hardware Versions (section 9.9 on Livebox web interface):

| Version          | Hardware          |
| ---------------- | ----------------- |
| Livebox7         | SMBS SMBSXLB7400  |
| Livebox6         | SMBS SMBSSGLB6107 |
| Livebox5         | SCOM SMBSSGLBF121 |
| Huawei HG8010Hv6 | HWTC HWTCA240FA   |


Note: If you encounter some DHCP issues and everything seems right, try to change the HWVER without modifying SERIAL number. For example, Huawei ONT serial number with a Livebox6 HWVER.

- Modify /etc/mibs/data_1g_8q_us1280_ds512.ini and /etc/mibs/data_1g_8q.ini :
```
cp /etc/mibs/data_1g_8q_us1280_ds512.ini  /etc/mibs/data_1g_8q_us1280_ds512.ini.org
cp /etc/mibs/data_1g_8q.ini  /etc/mibs/data_1g_8q.ini.orig
```
replace line 15 (^256): 
```
   # ONT-G
   256 0 HWTC 0000000000000 00000000 2 0 0 0 0 #0
   ```

The order is VendorID/Hardware Version (14 octets) and Serial Number (8 octets).  
The Serial Number (00000000) is automatically replaced by the configured value.
The VendorID/Hardware Version is only required for OLT ALCL (OLT HWTC do NOT verify it).

with (xxxxx is the Hardware Version not the serial number, try one of the following line) :
```
   # ONT-G
   #256 0 SCOM SMBSSGLBF121\0\0 00000000 2 0 0 0 0 #0
   256 0 SMBS SMBSSGLB6107\0\0 00000000 2 0 0 0 0 #0
```

for example:
```
256 0 SMBS SMBSSGLB6107\0\0 00000000 2 0 0 0 0 #0
256 0 SCOM SMBSSGLBF121\0\0 00000000 2 0 0 0 0 #0
```

note: this is corresponding to section 9.9 Hardware Version on Orange Livebox6
```
256 0 SMBS SMBSSGLB6107\0\0 00000000 2 0 0 0 0 #0
```

- reboot :
```

fw_printenv mib_file
reboot
```

- Check VLAN after reboot :
```
gtop  # then press c+y
```

**If VLAN are appearing, enjoy and skip the next following lines.** 

- If no VLAN are present, try the following :

- Enable the other mib_file data_1g_8q_us1280_ds512 and reboot again :
```
fw_setenv mib_file data_1g_8q_us1280_ds512.ini
fw_printenv mib_file
reboot
```

- Finally, check VLAN :
```
gtop  # then press c+y
```

- For information :
The line ^256 :
 - Managed entity ID : 0
 - Vendor ID : the first 4 characters are the first characters of SN (SMBS)
 - Hardware Version (14 octets, BUT ONLY 13 are accepted) : for example SMBSSGLB6107\0
 - Serial number (8 octets) : for example SMBS0123
 - ... DO NOT TOUCH THE REST
The line ^257, there is Equipment ID (20 octets), but it is not necessary for Orange

- To revert to default mib_file (/etc/mibs/data_1g_8q.ini)
```
fw_setenv mib_file data_1g_8q.ini
```
You could also just UNSET mib_file
```
fw_setenv mib_file
fw_printenv mib_file
```


### Speed issues

https://hack-gpon.github.io/ont-fs-com-gpon-onu-stick-with-mac/#enabling-data_1g_8q_us1280_ds512ini-omci-mib-file-for-2500-mbps-profiles
https://lafibre.info/remplacer-livebox/guide-de-connexion-fibre-directement-sur-un-routeur-voire-meme-en-2gbps/msg992075/#msg992075
https://github.com/akhamar/orange-2500mbps-G010SP/blob/master/README.md

DO NOT FORGET TO FORCE full-duplex 2.5Gbps on CRS305/310 : 
```
/interface/ethernet set auto-negotiation=no sfp-sfpplusX set speed=2.5Gbps sfp-sfpplusX
```

- If it always do not work as expected try to modify MIB file (/etc/mibs/data_1g_8q_us1280_ds512.ini). See the section above about VLANs issues.

- Try to enable `data_1g_8q_us1280_ds512.ini` mib_file (with or without modifications see above)

### Signal issues
Check ONU signal status with otop (otop + press S)
it should show something like this :
```
status overview

chip version (fuse format)                         A22  (1)
driver version (otop version)                      7.5.1  (7.5.1.0)
state history                                      9 8 4 3 2 1 6 0 0 0
config reads                                       + + + + + + + +
table reads                                        + + + + +
PLL lock status                                    locked
Signal detect                                      true
manage mode (OMU/BOSA/BOSA2), powerlevel           BOSA, normal (0)
manual mode, BERT mode, BOSA loop mode             off, off, dual-loop
laser age (active time)                            5:47:54
laser temperature (ext corr):                      319K
die temperature (int corr)                         317K
rx offset correction                               0
maximum bias / modulation current (chip)           78.00mA / 95.00mA
precalc. bias / modulation current                 9.19mA / 34.59mA (6)
actual bias / modulation current                   8.72mA / 34.18mA
bias / modulation change (errors)                  stable / stable (0 / 0)
integration coefficient bias / modulation          7 / 7
gain correction factor P0 / P1                     1.04 / 1.05
MPD target P0 / P1                                  +92 / +1088
MPD actual P0 / P1 (variation to target)           n/a
current offset                                     140.20uA
RSSI 1490 voltage, current                         127.75mV   127.75uA
RSSI 1550 voltage                                  499.51mV
RF 1550 voltage                                    499.27mV
DDMI voltage                                       3206.79mV
RSSI 1490 power                                    17.01uW -17.57dBm
tx power (se*(bias+mod/2-ith))                     1.80mW 2.55dBm
precalc. dcdc apd voltage, saturation              36.17V 152 (4)
DCDC APD target voltage (active/inactive)          36.17V (active)
DCDC APD voltage (regulation error), saturation    36.28V (+0.00V) 152
linear LDO converter (active/inactive)             (inactive)
```


## Others commands
https://hack-gpon.github.io/ont-fs-com-gpon-onu-stick-with-mac/

```
sfp_i2c -s <sn> -i 3 # SN on SFP side to RouterOS
sfp_i2c -s <sn> -i 8 # SN on GPON side to ISP OLT
sfp_i2c -s <sn> -i 11 
uci show
```

## Other Enhancements
https://hack-gpon.github.io/ont-fs-com-gpon-onu-stick-with-mac/

### TX Fault / Serial

The stick stays in a perpetual “TX Fault” state since the same SFP pin is used for both serial and TX Fault signaling, if that causes you issues (normally it shouldn’t) you can issue the commands below to disable it. Note that it will disable both the TX Fault signal and Serial on the stick after boot.

fw_setenv asc0 1
fw_setenv preboot "gpio set 3;gpio input 100;gpio input 105;gpio input 106;gpio input 107;gpio input 108"
In case you need to re-enable it issue the following commands from the bootloader (FALCON)
FALCON => setenv asc0 0
FALCON => saveenv


### Getting/Setting Speed LAN Mode

To get the LAN Mode:
```
onu lanpsg 0
```

The link_status variable tells the current speed.
See the section about SGMII mode below.

## Complete reset

To completely reset the ONU just run the following commands. The reconfigure the ONU from scratch…
```
firstboot
reboot
```
