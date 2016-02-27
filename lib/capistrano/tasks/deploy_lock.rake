namespace :deploy_lock do
  # Fetch the deploy lock unless already cached
  def fetch_deploy_lock(server)
    # Return if we know that the deploy lock has just been removed
    return if fetch(:deploy_lock_removed)

    if fetch(:deploy_lock).nil?
      # Check all matching servers for a deploy lock.
      if test "[ -e #{fetch(:deploy_lockfile)} ]"
        output = capture "cat #{fetch(:deploy_lockfile)}"

        if output && output != ''
          info "Deploy lock found on: #{server.hostname}"
          set :deploy_lock, YAML.load(output)
          return
        end
      end

      set :deploy_lock, false
    end
  end

  def write_deploy_lock(deploy_lock)
    upload! StringIO.new(deploy_lock.to_yaml), fetch(:deploy_lockfile)
  end

  def remove_deploy_lock
    execute :rm, '-f', fetch(:deploy_lockfile)
    set :deploy_lock, nil
    set :deploy_lock_removed, true
  end

  desc "Set deploy lock with a custom lock message and expiry time"
  task :lock do
    on roles :all, exclude: :no_release do
      ask(:lock_message, 'This deployment has been locked')
      set :custom_deploy_lock, true

      while fetch(:lock_expiry).nil?
        ask(:expiry_str, (Time.now + 10*60).strftime('%Y-%m-%dT%H:%M:%S%z'))
        expiry_str = fetch(:expiry_str)
        if expiry_str == ""
          # Never expire an explicit lock if no time given
          set :lock_expiry, false
        else
          parsed_expiry = nil
          if defined?(Chronic)
            parsed_expiry = Chronic.parse(expiry_str) || Chronic.parse("#{expiry_str} from now")
          elsif dt = (DateTime.parse(expiry_str) rescue nil)
            parsed_expiry = dt.to_time
          end

          if parsed_expiry
            set :lock_expiry, parsed_expiry.utc
          else
            info "'#{expiry_str}' could not be parsed. Please try again."
          end
        end
      end

      invoke 'deploy_lock:create_lock'
    end
  end

  desc "Creates a lock file, so that futher deploys will be prevented"
  task :create_lock do
    on roles :all, exclude: :no_release do
      if fetch(:deploy_lock)
        info 'Deploy lock already created.'
        next
      end

      if fetch(:lock_message).nil?
        set :lock_message, "Deploying #{fetch(:branch)} branch"
      end
      if fetch(:lock_expiry).nil?
        set :lock_expiry, (Time.now + fetch(:default_lock_expiry)).utc
      end

      deploy_lock_data = {
        :created_at => Time.now.utc,
        :username   => ENV['USER'],
        :expire_at  => fetch(:lock_expiry),
        :message    => fetch(:lock_message).to_s,  # .to_s makes a String out of Highline::String
        :custom     => !!fetch(:custom_deploy_lock)
      }
      write_deploy_lock(deploy_lock_data)

      set :deploy_lock,  deploy_lock_data
    end
  end

  desc "Unlocks the server for deployment"
  task :unlock do
    on roles :all, exclude: :no_release do
      within deploy_path do
        # Don't automatically remove custom deploy locks created by deploy:lock task
        if fetch(:custom_deploy_lock)
          info 'Not removing custom deploy lock.'
        else
          remove_deploy_lock
        end
      end
    end
  end

  desc 'Remove all locks'
  task :force_unlock do
    on roles :all, exclude: :no_release do
      remove_deploy_lock
    end
  end

  desc "Checks for a deploy lock. If present, deploy is aborted and message is displayed. Any expired locks are deleted."
  task :check_lock do
    on roles :all, exclude: :no_release do |server|
      # Don't check the lock if we just created it
      next if fetch(:deploy_lock)

      fetch_deploy_lock(server)
      # Return if no lock
      next unless fetch(:deploy_lock)
      deploy_lock = fetch(:deploy_lock)

      if deploy_lock[:expire_at] && deploy_lock[:expire_at] < Time.now
        info Capistrano::DeployLock.expired_message(fetch(:application), stage, deploy_lock)
        remove_deploy_lock
        next
      end

      # Check if lock is a custom lock
      set :custom_deploy_lock, deploy_lock[:custom]

      # Unexpired lock is present, so display the lock message
      warn Capistrano::DeployLock.message(fetch(:application), (respond_to?(:stage) ? stage : nil), deploy_lock)

      # Don't raise exception if current user owns the lock, and lock has an expiry time.
      # Just sleep for a few seconds so they have a chance to cancel the deploy with Ctrl-C
      if deploy_lock[:expire_at] && deploy_lock[:username] == ENV['USER']
        5.downto(1) do |i|
          Kernel.print "\rDeploy lock was created by you (#{ENV['USER']}). Continuing deploy in #{i}..."
          sleep 1
        end
        puts
      else
        exit 1
      end
    end
  end

  desc "Refreshes an existing deploy lock's expiry time, if it is less than the default time"
  task :refresh_lock do
    on roles :all, exclude: :no_release do |server|
      fetch_deploy_lock(server)
      next unless fetch(:deploy_lock)

      deploy_lock = fetch(:deploy_lock)

      # Don't refresh custom locks
      if deploy_lock[:custom]
        info 'Not refreshing custom deploy lock.'
        next
      end

      # Refresh lock expiry time if it's going to expire
      if deploy_lock[:expire_at] && deploy_lock[:expire_at] < (Time.now + default_lock_expiry)
        info "Resetting lock expiry to default..."
        deploy_lock[:username]  = ENV['USER']
        deploy_lock[:expire_at] = (Time.now + default_lock_expiry).utc

        write_deploy_lock(deploy_lock)
      end
    end
  end

  before "deploy:starting", "deploy_lock:check_lock"
  before "deploy:starting", "deploy_lock:refresh_lock"
  before "deploy:starting", "deploy_lock:create_lock"
  after  "deploy:finished", "deploy_lock:unlock"
end

namespace :deploy do
  desc "Deploy with a custom deploy lock"
  task :with_lock do
    on roles :all, exclude: :no_release do
      invoke 'deploy_lock:lock'
      invoke 'deploy'
    end
  end
end

# Set defaults.
namespace :load do
  task :defaults do
    # Default lock expiry of 10 minutes (in case deploy crashes or is interrupted)
    set :default_lock_expiry, fetch(:default_lock_expiry, (10 * 60))
    set :deploy_lockfile_name, fetch(:deploy_lockfile_name, 'capistrano.lock.yml')
    set :deploy_lockfile, -> { deploy_path.join(fetch(:deploy_lockfile_name)) }
  end
end
