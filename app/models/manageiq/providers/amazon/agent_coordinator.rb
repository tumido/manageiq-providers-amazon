require 'yaml'
require 'open3'
require 'net/scp'
require 'linux_admin'
require 'amazon_ssa_support'

class ManageIQ::Providers::Amazon::AgentCoordinator
  include Vmdb::Logging
  attr_accessor :ems, :deploying

  MIQ_SSA = "MIQ_SSA".freeze
  MIQ_DIR = "/var/www/miq".freeze

  def initialize(ems)
    @ems = ems

    # List of active agent ids
    @alive_agent_ids = []

    # List of all agent ids, include those in power off state.
    @agent_ids = []
    @deploying = false
  end

  def ec2
    @ec2 ||= ems.connect(:service => 'EC2')
  end

  def sqs
    @sqs ||= ems.connect(:service => 'SQS')
  end

  def s3
    @s3 ||= ems.connect(:service => 'S3')
  end

  def iam
    @iam ||= ems.connect(:service => 'IAM')
  end

  def alive_agent_ids(interval = 180)
    @alive_agent_ids = agent_ids.select { |id| agent_alive?(id, interval) }
  end

  def request_queue_empty?
    messages_in_queue(request_queue).zero?
  end

  def reply_queue_empty?
    messages_in_queue(reply_queue).zero?
  end

  def deploying?
    @deploying
  end

  def startup_agent
    agent_ids.empty? ? deploy_agent : activate_agents
  rescue => err
    _log.error("No agent is set up to prcoess requests: #{err.message}")
    _log.error(err.backtrace.join("\n"))
  end

  def scp_file(local_file, remote_file, instance, username = "centos")
    ip = instance.public_dns_name
    key_name = instance.key_name
    auth_key = get_keypair(key_name).try(:auth_key)
    _log.error("AuthKey #{key_name} is empty of #{instance.id}") if auth_key.nil?
    Net::SCP.upload!(ip, username, local_file, remote_file, :ssh => {:key_data => auth_key})
  rescue => err
    _log.error(err.message)
  end

  def ssh_commands(instance, commands = [], username = "centos")
    ip = instance.public_dns_name
    key_name = instance.key_name
    auth_key = get_keypair(key_name).try(:auth_key)
    _log.error("AuthKey #{key_name} is empty of #{instance.id}") if auth_key.nil?
    ssh = LinuxAdmin::SSH.new(ip, username, auth_key)
    ssh.perform_commands(commands)
  end

  private

  def agent_ids
    # reset to empty
    @agent_ids = []

    bucket = s3.bucket(ssa_bucket)
    return @agent_ids unless bucket.exists?

    bucket.objects(:prefix => heartbeat_prefix).each do |obj|
      id = obj.key.split('/')[2]
      @agent_ids << id if ec2.instance(id).exists?
    end

    @agent_ids
  end

  # check timestamp of heartbeat of agent_id, return true if the last beat time in
  # in the time interval
  def agent_alive?(agent_id, interval = 180)
    bucket = s3.bucket(ssa_bucket)
    return false unless bucket.exists?

    obj_id = "#{heartbeat_prefix}#{agent_id}"
    obj = bucket.object(obj_id)
    return false unless obj.exists?

    last_heartbeat = obj.last_modified
    _log.debug("#{obj.key}: Last heartbeat time stamp: #{last_heartbeat}")

    Time.now.utc - last_heartbeat < interval && ec2.instance(agent_id).state.name == "running"
  rescue => err
    _log.error("#{agent_id}: #{err.message}")
    false
  end

  def activate_agents
    agent_ids.each do |id|
      agent = ec2.instance(id)
      if agent.state.name == "stopped"
        agent.start
        agent.wait_until_running
        _log.info("Agent #{id} is activated to serve requests.")
        return id
      else
        _log.warn("Agent #{id} is in abnormal state: #{agent.state.name}.")
        next
      end
    end

    _log.error("Failed to activate agents: #{agent_ids}.")
  end

  def deploy_agent
    _log.info("Deploying agent ...")
    @deploying = true

    kp = find_or_create_keypair
    security_group_id = find_or_create_security_group
    zone_name = ec2.client.describe_availability_zones.availability_zones[0].zone_name
    subnets = get_subnets(zone_name)
    raise "No subnet_id is available for #{zone_name}!" if subnets.empty?
    find_or_create_profile

    instance                = ec2.create_instances(
      :image_id             => get_agent_image_id,
      :min_count            => 1,
      :max_count            => 1,
      :key_name             => kp.name,
      :security_group_ids   => [security_group_id],
      :instance_type        => 't2.micro',
      :placement            => {
        :availability_zone => zone_name
      },
      :subnet_id            => subnets[0].subnet_id,
      :iam_instance_profile => {
        :name => label
      },
      :tag_specifications   => [{
        :resource_type => "instance",
        :tags          => [{
          :key   => "Name",
          :value => label
        }]
      }]
    )
    ec2.client.wait_until(:instance_status_ok, :instance_ids => [instance[0].id])

    _log.info("Start to load SSA application, this may take a while ...")

    setup_agent(instance[0])
    _log.info("SSA agent is ready to receive requests.")

    instance[0].id
  end

  def setup_agent(instance)
    # register if needed
    register(instance)

    # prepare work directory
    ssh_commands(instance, ["sudo mkdir -p #{MIQ_DIR}; sudo chmod go+w #{MIQ_DIR}"])
    # TODO: for testing purpose. need to remove.
    ssh_commands(instance, ["sudo mkdir -p /opt/miq/log; sudo chmod go+w /opt/miq/log"])

    # scp the setup script
    scp_file(agent_setup_script, MIQ_DIR.to_s, instance)

    # scp the gem file
    scp_file(agent_gem_file, MIQ_DIR.to_s, instance)

    # scp the default setting yaml file
    create_setting_yaml("data/default_ssa_config.yml")
    scp_file("data/default_ssa_config.yml", MIQ_DIR.to_s, instance)

    # run setup script
    script = "#{MIQ_DIR}/#{agent_setup_script.split('/').last}"
    ssh_commands(instance, ["sudo chmod +x #{script}"])
    ssh_commands(instance, ["WORK_DIR=#{MIQ_DIR} AGENT_RUBY_VERSION=#{agent_ruby_version} AGENT_LOG_LEVEL=#{agent_log_level} sudo -E #{script}"])
  end

  # TODO: for downstream
  def register(instance)
  end

  # Get Key Pair for SSH. Create a new one if not exists.
  def find_or_create_keypair(keypair_name = key_name)
    get_keypair(keypair_name) || begin
      _log.info("KeyPair #{keypair_name} will be created!")
      ManageIQ::Providers::CloudManager::AuthKeyPair.create_key_pair(@ems.id, :key_name => keypair_name)
    end
  end

  def get_keypair(keypair_name = key_name)
    kps = @ems.authentications.where(:name => keypair_name)
    kps.any? ? kps[0] : nil
  end

  def find_or_create_profile(profile_name = label, role_name = label)
    ssa_profile = iam.instance_profile(profile_name)
    ssa_profile = iam.create_instance_profile(:instance_profile_name => profile_name) unless ssa_profile.exists?

    find_or_create_role(role_name)
    ssa_profile.add_role(:role_name => role_name) if ssa_profile.roles.empty?

    ssa_profile
  end

  def find_or_create_role(role_name = label)
    return iam.role(role_name) if role_exists?(role_name)

    # Policy Generator:
    policy_doc = {
      :Version   => "2012-10-17",
      :Statement => {
        :Effect    => "Allow",
        :Principal => {
          :Service => "ec2.amazonaws.com"
        },
        :Action    => "sts:AssumeRole"
      }
    }

    role = iam.create_role(
      :role_name                   => role_name,
      :assume_role_policy_document => policy_doc.to_json
    )

    role
  end

  def role_exists?(role_name)
    role = iam.role(role_name)
    role.role_id
    true
  rescue ::Aws::IAM::Errors::NoSuchEntity
    false
  end

  def find_or_create_security_group(group_name = label)
    sgs = ec2.client.describe_security_groups(
      :filters => [{
        :name   => "group-name",
        :values => [group_name]
      }]
    ).security_groups
    return sgs[0].group_id unless sgs.empty?

    # create security group if not exist
    security_group = ec2.create_security_group(
      :group_name  => group_name,
      :description => 'Security group for MIQ SSA Agent',
      :vpc_id      => ec2.client.describe_vpcs.vpcs[0].vpc_id
    )

    security_group.authorize_ingress(
      :ip_permissions => {
        :ip_protocol => 'tcp',
        :from_port   => 22,
        :to_port     => 22,
        :ip_ranges   => {
          :cidr_ip => '0.0.0.0/0'
        }
      }
    )

    security_group.authorize_ingress(
      :ip_permissions => {
        :ip_protocol => 'tcp',
        :from_port   => 80,
        :to_port     => 80,
        :ip_ranges   => {
          :cidr_ip => '0.0.0.0/0'
        }
      }
    )

    security_group.authorize_ingress(
      :ip_permissions => {
        :ip_protocol => 'tcp',
        :from_port   => 443,
        :to_port     => 443,
        :ip_ranges   => {
          :cidr_ip => '0.0.0.0/0'
        }
      }
    )

    security_group.group_id
  end

  def get_subnets(az)
    ec2.client.describe_subnets(
      :filters => [{
        :name   => "availability-zone",
        :values => [az]
      }]
    ).subnets
  end

  # possible RHEL image name: values: [ "RHEL-7.3_HVM_GA*" ]
  def get_agent_image_id(image_name = agent_ami_name)
    imgs = ec2.client.describe_images(
      :filters => [{
        :name   => "name",
        :values => [image_name]
      }]
    ).images

    imgs[0].image_id
  end

  def create_pem_file(pair_name = keypair_name)
    kp = find_or_create_keypair(pair_name)
    pem_file_name = "#{pair_name}.pem"
    File.write(pem_file_name, kp.auth_key)
    File.chmod(0o400, pem_file_name)
    pem_file_name
  end

  def create_setting_yaml(yml = "default_ssa_config.yml")
    defaults = agent_coordinator_settings.to_hash
    defaults[:region] = region
    defaults[:request_queue] = request_queue
    defaults[:reply_queue] = reply_queue
    defaults[:ssa_bucket] = ssa_bucket
    File.write(yml, defaults.to_yaml)
  end

  def messages_in_queue(q_name)
    q = sqs.get_queue_by_name(:queue_name => q_name)
    q.attributes["ApproximateNumberOfMessages"].to_i + q.attributes["ApproximateNumberOfMessagesNotVisible"].to_i
  rescue => err
    _log.warn(err.message)
    0
  end

  def agent_coordinator_settings
    @agent_coordinator_settings ||= Settings.ems.ems_amazon.agent_coordinator
  end

  def region
    @ems.provider_region
  end

  def agent_log_level
    ll = agent_coordinator_settings.try(:agent_log_level) || AmazonSsaSupport::DEFAULT_LOG_LEVEL
    ll.upcase
  end

  def heartbeat_prefix
    AmazonSsaSupport::DEFAULT_HEARTBEAT_PREFIX
  end

  def heartbeat_interval
    agent_coordinator_settings.try(:heartbeat_interval) || AmazonSsaSupport::DEFAULT_HEARTBEAT_INTERVAL
  end

  def ssa_bucket
    @ssa_bucket ||= "#{AmazonSsaSupport::DEFAULT_BUCKET_PREFIX}-#{@ems.guid}"
  end

  def request_queue
    @request_queue ||= "#{AmazonSsaSupport::DEFAULT_REQUEST_QUEUE}-#{@ems.guid}"
  end

  def reply_queue
    @reply_queue ||= "#{AmazonSsaSupport::DEFAULT_REPLY_QUEUE}-#{@ems.guid}"
  end

  def reply_prefix
    AmazonSsaSupport::DEFAULT_REPLY_PREFIX
  end

  def log_prefix
    AmazonSsaSupport::DEFAULT_LOG_PREFIX
  end

  def agent_ami_name
    agent_coordinator_settings.try(:agent_ami_name) || raise { "Please specify AMI image name for SSA agent" }
  end

  def agent_ruby_version
    agent_coordinator_settings.try(:agent_ruby_version) || raise { "Please specify Ruby version for SSA agent" }
  end

  def agent_setup_script
    "#{Gem.loaded_specs['manageiq-providers-amazon'].full_gem_path}/#{agent_coordinator_settings.agent_setup_script}"
  end

  def agent_gem_file
    "#{Gem.loaded_specs['manageiq-providers-amazon'].full_gem_path}/#{agent_coordinator_settings.agent_gem_file}"
  end

  # This label is used to name all objects (profile/role/instance, etc) we created in AWS.
  # Make it configurable for upstream/downstream name conventions
  def label
    @label ||= agent_coordinator_settings.try(:agent_label) || MIQ_SSA
  end

  def key_name
    "#{label}-#{@ems.guid}"
  end
end
