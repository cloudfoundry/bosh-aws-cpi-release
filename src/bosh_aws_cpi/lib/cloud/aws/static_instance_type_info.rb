module Bosh::AwsCloud
  # Determines NVMe characteristics of EC2 instance types using hardcoded family lists,
  # requiring no IAM permissions. Use when ec2:DescribeInstanceTypes is unavailable.
  #
  # EBS NVMe families (Nitro): EBS volumes are exposed as NVMe devices, requiring
  # /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_* paths.
  #
  # Instance storage NVMe families: local instance storage uses /dev/nvme*n1 naming.
  # Includes i3 (Xen-based but NVMe instance storage) and all Nitro families with local NVMe SSDs.
  class StaticInstanceTypeInfo
    NVME_EBS_FAMILIES = %w[
      a1
      c5 c5a c5ad c5d c5n
      c6a c6g c6gd c6gn c6i c6id c6in
      c7a c7g c7gd c7gn c7i c7in
      d3 d3en
      g4ad g4dn g5 g5g g6 g6e g6g
      hpc7a hpc7g
      i3en i4g i4i i7ie i8g
      im4gn is4gen
      inf1 inf2
      m5 m5a m5ad m5d m5dn m5n m5zn
      m6a m6g m6gd m6i m6id m6idn m6in
      m7a m7g m7gd m7i m7i-flex
      p3dn p4d p4de p5 p5e
      r5 r5a r5ad r5b r5d r5dn r5n
      r6a r6g r6gd r6i r6id r6idn r6in
      r7a r7g r7gd r7i r7iz
      t3 t3a t4g t4gn
      trn1 trn1n
      u-3tb1 u-6tb1 u-9tb1 u-12tb1 u-18tb1 u-24tb1
      vt1
      x2gd x2idn x2iedn x2iezn
      z1d
    ].freeze

    # Families with local NVMe instance storage (i3 is Xen but has NVMe local storage).
    NVME_INSTANCE_STORAGE_FAMILIES = %w[
      c5ad c5d
      c6id
      c7gd
      d3 d3en
      g4dn g5 g6 g6e
      i3 i3en i4g i4i i7ie i8g
      im4gn is4gen
      m5ad m5d
      m6id m6idn
      m7gd
      p3dn p4d p4de p5 p5e
      r5ad r5b r5d
      r6id r6idn
      r7gd
      trn1 trn1n
      x2gd x2idn x2iedn x2iezn
      z1d
    ].freeze

    def ebs_requires_nvme_path?(instance_type)
      NVME_EBS_FAMILIES.include?(instance_family(instance_type))
    end

    def instance_storage_nvme_naming?(instance_type)
      NVME_INSTANCE_STORAGE_FAMILIES.include?(instance_family(instance_type))
    end

    private

    def instance_family(instance_type)
      return nil if instance_type.nil?
      instance_type.split('.').first
    end
  end
end
