# commands used to deploy a Rails application
namespace :fly do
  # BUILD step:
  #  - changes to the filesystem made here DO get deployed
  #  - NO access to secrets, volumes, databases
  #  - Failures here prevent deployment
  task :build => 'assets:precompile'

  # RELEASE step:
  #  - changes to the filesystem made here are DISCARDED
  #  - full access to secrets, databases
  #  - failures here prevent deployment
  task :release

  task :env do
    ENV['REDIS_URL'] = "redis://#{ENV['FLY_REGION']}-redis.local:6379/1"
    ENV['ANYCABLE_GO_RPC_HOST'] = "#{ENV['FLY_REGION']}-anycable-rpc.local:50051"
  end

  # SERVER step:
  #  - changes to the filesystem made here are deployed
  #  - full access to secrets, databases
  #  - failures here result in VM being stated, shutdown, and rolled back
  #    to last successful deploy (if any).
  task :server, [:formation] => [:swapfile, "db:migrate"] do |task, args|
    formation = args[:formation] || "web=1;redis=1;anycable-rpc=1;anycable-go=1"
    formation.gsub! ';', ','
    Rake::Task['fly:avahi_publish'].invoke(formation)
    Bundler.with_original_env do
      Rake::Task['fly:env'].invoke
      sh "foreman start --procfile=Procfile.fly --formation=#{formation}"
    end
  end

  # optional SWAPFILE task:
  #  - adjust fallocate size as needed
  #  - performance critical applications should scale memory to the
  #    point where swap is rarely used.  'fly scale help' for details.
  #  - disable by removing dependency on the :server task, thus:
  #        task :server => 'db:migrate' do
  task :swapfile do
    sh 'fallocate -l 512M /swapfile'
    sh 'chmod 0600 /swapfile'
    sh 'mkswap /swapfile'
    sh 'echo 10 > /proc/sys/vm/swappiness'
    sh 'swapon /swapfile'
    sh 'echo 1 > /proc/sys/vm/overcommit_memory'
  end
end
