# Spot provisioning via `RunInstances` + `InstanceMarketOptions`

The bosh-aws-cpi provisions Spot instances with **`ec2:RunInstances`** and **`InstanceMarketOptions`**, not **`RequestSpotInstances`**. This note is scoped to that **spot API migration** only (separate from broader “tag at creation” work elsewhere in the CPI).

## Why change APIs?

`RequestSpotInstances` uses a different launch payload than `RunInstances` and historically could not carry the same launch parameters as the on-demand path. Spot is therefore folded into the **same `RunInstances` call shape** as on-demand, with optional **`instance_market_options`** when `spot_bid_price` is set in the manifest.

## Parity (launch parameters)

Spot uses the same **`InstanceParamMapper#instance_params`** hash as on-demand (image, type, key, IAM profile, user data, block devices, metadata options, network interfaces, placement, plus whatever optional fields the mapper adds today). The CPI adds:

- `min_count` / `max_count` of 1
- `instance_market_options`: `market_type: 'spot'`, `spot_options` with `max_price` from **`spot_bid_price`**, `spot_instance_type: 'one-time'`, `instance_interruption_behavior: 'terminate'`

If **`security_groups`** appears on the launch hash (classic / name-based path the CPI does not support for spot), creation fails with the same error as before.

## Behavioral differences vs `RequestSpotInstances`

1. **Fulfillment:** Legacy flow returned a Spot Instance Request id and **polled** until fulfilled or timed out. **`RunInstances`** succeeds with a **reservation / instance id** or **fails the call immediately** (for example capacity errors).

2. **Response handling:** Instance id comes from **`run_instances` → `instances[0].instance_id`**, identical to on-demand.

3. **`spot_ondemand_fallback`:** On **`Bosh::Clouds::VMCreationFailed`** from the spot attempt, the CPI runs **`run_instances` again** without `instance_market_options`. Any **`Aws::EC2::Errors::ServiceError`** from the spot attempt is wrapped in **`VMCreationFailed`**, same outer contract as before.

## IAM

Spot no longer needs **`ec2:RequestSpotInstances`**, **`ec2:DescribeSpotInstanceRequests`**, or **`ec2:CancelSpotInstanceRequests`**. **`ec2:RunInstances`** (already required for on-demand VMs) covers Spot via market options.

## References

- AWS EC2: `RunInstances`, `InstanceMarketOptionsRequest`, `SpotMarketOptions`
- In-repo history: commit `12980a11` (legacy spot launch spec and tags)
