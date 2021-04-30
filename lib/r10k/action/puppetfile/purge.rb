require 'r10k/puppetfile'
require 'r10k/util/cleaner'
require 'r10k/action/base'
require 'r10k/errors/formatting'

module R10K
  module Action
    module Puppetfile
      class Purge < R10K::Action::Base

        def call
          pf = R10K::Puppetfile.new(@root, @moduledir, @puppetfile)
          pf.load!
          R10K::Util::Cleaner.new(pf.managed_directories,
                                  pf.desired_contents,
                                  pf.purge_exclusions).purge!

          true
        rescue => e
          logger.error R10K::Errors::Formatting.format_exception(e, @trace)
          false
        end

        private

        def allowed_initialize_opts
          super.merge(root: :self, puppetfile: :self, moduledir: :self)
        end
      end
    end
  end
end
