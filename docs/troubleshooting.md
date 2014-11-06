## Troubleshooting

### Signature expired error

```
$ out/bosh-micro deploy aws-cpi-0+dev.48.tgz
...
Started Deploy Micro BOSH
Started Deploy Micro BOSH > Creating VM from 'ami-fec37996 light'. Failed 'creating vm with stemcell cid `ami-fec37996 light': External CPI command for method `create_vm' returned an error: CmdError{"type":"Unknown","message":"Signature expired: 20141106T010406Z is now earlier than 20141106T011252Z (20141106T011752Z - 5 min.)","ok_to_retry":false}' (00:00:43)
[main] 2014/11/06 01:04:06 ERROR - BOSH Micro CLI failed with: Deploying Microbosh: Creating VM: creating vm with stemcell cid `ami-fec37996 light': External CPI command for method `create_vm' returned an error: CmdError{"type":"Unknown","message":"Signature expired: 20141106T010406Z is now earlier than 20141106T011252Z (20141106T011752Z - 5 min.)","ok_to_retry":false}
```

This error is usually caused by out-of-sync system time. Use ntpdate to sync the clock.

```
$ sudo ntpdate pool.ntp.org
 6 Nov 18:17:56 ntpdate[29268]: step time server 74.207.240.206 offset 0.598687 sec
```

 Alternatively make sure that NTP service is correctly configured and running.
