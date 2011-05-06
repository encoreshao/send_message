# encoding: utf-8

#
# Impression 
# Time: 2010-01-21
#
module SendMessage 
  module Backend
    module Impression # nodoc...

      def self.included( base )
        base.extend ClassMethods 
        base.class_eval { include InstanceMethods, ImpressionBefore }
      end

      module ClassMethods
        #
        # About method_missing .
        # Please Rewirte Three methods [:impression_key, :counter_key, :latest_list_key] .
        #
        def verify_impression_keys_methods
          raise NoMehtodError, "Undefined Method impression_key for #{self.class.class_name}" unless respond_to?(:impression_key)
          raise NoMehtodError, "Undefined Method counter_key for #{self.class.class_name}" unless respond_to?(:counter_key)
          raise NoMehtodError, "Undefined Method latest_list_key for #{self.class.class_name}" unless respond_to?(:latest_list_key) 
          raise NoMehtodError, "Undefined Method impression_validate_limit_key for #{self.class.class_name}" unless respond_to?(:impression_validate_limit_key) 
        end 
      end

      module InstanceMethods
      
        #
        # Set latest_impression Impression Record .
        # Set @@limit_count Please Rewirte limit_count Method .
        #
        @@limit_count = respond_to?(:limit_count) && limit_count || 10 

        #
        # Get impressions . 
        #
        def impressions( options = {} )
          $redis.zrevrange impression_key,
            0, (options.try( :[], :limit) || 0) - 1,
            :with_scores => options.try(:[], :with_count)
        end

        #
        # Get List Impressions . 
        #
        def latest_list_impressions( options = {} )
          $redis.zrevrange latest_list_key,
            0, (options.try( :[], :limit) || 0) - 1,
            :with_scores => options.try(:[], :with_count)
        end

        #
        # Create Errors Object .
        #
        def impression_errors
          @impression_errors ||= ActiveRecord::Errors.new( self )
        end
        
        #
        # Validate impression_title and impression_number .
        #
        def impression_validates( impression_title, impression_number )
          impression_errors.add_to_base('Please write impression' ) if impression_title.blank?
          impression_errors.add_to_base('lg five ') if impression_title.mb_chars.size > 5
          impression_errors.add_to_base('TYPEERRORS') unless impression_number.is_a?(Integer)
          impression_errors.add_to_base('less only one') if impression_number.is_a?(Integer) && impression_number < 1
        end

        # Set amount_key
        def impression_amount_key(session_id)
          impression_validate_limit_key + "#{session_id}:limit"
        end

        #
        # Validate impression_id
        #
        def impression_count_validates(session_id)
          key = impression_amount_key(session_id)
          expired_at = (Time.now.tomorrow.at_beginning_of_day - Time.now).to_i
          validate_impression_count(key, expired_at)
        end


        #
        # Page Front validate impression Count
        # Validate impression_count
        #
        def validate_impression_count(key, expired_at)
          if Rails[:cache].get(key).nil?
            Rails[:cache].set(key, 1, expired_at)
          elsif  Hejia[:cache].get(key) == 1
            Rails[:cache].set(key, 2, expired_at)
          elsif Rails[:cache].get(key) == 2
            impression_errors.add_to_base('Sorry, one day only two impression')
          end
        end


        #
        # Verify through .
        #
        def impression_valid?
          impression_errors.empty?
        end

        #
        # @note::  前台后台都在使用
        # Add Impression Info . 
        # Hejia :: object.add_impression(title, number)
        # Page Front Usage :: object.add_impression(title, number, false, session_id)
        #
        def add_impression( impression_title, impression_number = 1, is_not_hejia = false, session_id = nil )
          # Add validates impression title : number 
          impression_validates( impression_title, impression_number )
          impression_count_validates(session_id) if is_not_hejia && impression_valid?
          # Last Add impression
          impression_valid? && modify_impression( impression_title, impression_number )
        end

        #
        # Update Impression Info . 
        # Need Recalculate
        # object.update_impression(title)
        #
        def update_impression( impression_title, impression_number = 1, is_not_hejia = false, session_id = nil )
          impression_validates( impression_title, impression_number, is_not_hejia, session_id )
          impression_count_validates(session_id) if is_not_hejia && impression_valid?
          # Need calculation difference_value
          impression_valid? && modify_impressi( impression_title, calculation_of_difference(impression_title, impression_number) )
        end

        #
        # Destory Impression Info . 
        # Need Recalculate
        # object.destroy_impression(title)
        #
        def destroy_impression( impression_title )
          impression_number = find_count_by_title(impression_title)
          remove_impression(impression_title, -impression_number) 
        end

        #
        # Modify the value of the difference between the old values
        # Find Difference Value
        # 
        def calculation_of_difference(impression_title, impression_number)
          amount_title = find_count_by_title(impression_title)
          amount_title == impression_number ? 0 : (amount_title > impression_number ? -(amount_title- impression_number) : (impression_number - amount_title))
        end

        #
        # Get impression top . 
        # options[:limit] count . 
        #
        def top_impressions( options = {} )
          options = options.merge!( {:with_count => true} )

          limit = ( options.try( :[], :limit ) || @@limit_count )
          limit_impressions = impressions( options )
          
          top = []
          0.step( limit.to_i * 2 - 1, 2 ) do |i|
            top << {:name => limit_impressions[i], :score => limit_impressions[i+1], :percent => format('%.1f', limit_impressions[i+1].to_f*100/impression_total_count)+'%'}
          end
          top
        end

        #
        # Get impression count . 
        #
        def impression_total_count
          $redis.get( counter_key ).to_i
        end

        #
        # Remove a certain amount from the total .
        #
        def unincrement_total_count(delete_count)
          $redis.set(counter_key, impression_total_count - delete_count)
        end

        #
        # Return latest impression .
        # Depends @@limit_count . 
        #
        def latest_impression
          $redis.zrevrange latest_list_key, 0, -1
        end

        private
          #
          # Number of queries under the title .
          #
          def find_count_by_title(impression_title)
            $redis.ZSCORE(impression_key, impression_title).to_i
          end

          #
          # Remove impression for Redis .
          #
          def remove_impression(impression_title, impression_number)
            $redis.multi
            $redis.ZREM impression_key, impression_title
            $redis.zrem latest_list_key, impression_title 
            $redis.incrby counter_key, impression_number
            $redis.exec
            true
          rescue
            Rails.logger.error $!
            Rails.logger.error $@.join("\n")
            $redis.discard
            false
          end

          #
          # Ready On Update Impression Redis . 
          #
          def modify_impression( impression_title, impression_number )
            $redis.multi
            # Cumulative number of records ( ordered set ) .
            $redis.zincrby impression_key, impression_number, impression_title
            # Impression of the total number of records ( string ) .
            $redis.incrby counter_key, impression_number

            # Handle the latest impression added ( ordered set ) .
            $redis.zadd latest_list_key, Time.now.to_i, impression_title
            $redis.zrem latest_list_key, $redis.zrange( latest_list_key, 0, 0 ).first if $redis.zcard( latest_list_key ).to_i > @@limit_count 
            $redis.exec
            true
          rescue
            Rails.logger.error $!
            Rails.logger.error $@.join("\n")
            $redis.discard
            false
          end

      end # InstanceMethods

    end # Impression

    module ImpressionBefore

      def self.included( base )
        base.extend ClassMethods
      end

      module ClassMethods

        #
        # Returns an array naming all wrapped methods.
        #
        def wrapped_methods
          @wrapped_methods ||= []
        end

        #
        # Installs wrappers for the named methods.
        #
        def wraps( *methods )
          methods.each { |method| wrap(method) }
        end

        protected

          #
          # Wraps the named method in 'before' and 'after' callbacks. Exits silently if the method
          # doesn't exist, or if it's already wrapped.
          #
          def wrap( method )
            # Can't wrap a method that doesn't exist.
            sym = method.to_sym
            return unless method_defined?( sym )

            # If the method already has a wrapper, don't bother.
            old_method = :"__#{sym}_without_callbacks__"
            new_method = :"__#{sym}_with_callbacks__"
            return if method_defined?( new_method )

            # Wrap the method in one that invokes callbacks.
            # args = params
            define_method( new_method ) do |*args|
              invocation = "#{self.class}##{new_method}( #{args} )"
              puts "----------"
              puts " Before #{invocation} "
              result = self.send( old_method, *args )
              puts "       #{invocation} returned #{result.inspect}"
              puts " After  #{invocation} "
              result
            end            
            alias_method old_method, sym
            alias_method sym, new_method

            # Record the fact that we wrapped this particular rascal.
            wrapped_methods << sym unless wrapped_methods.include?( sym )
          end
      end # ClassMethods
    end # ImpressionBefore
  end
end # SendMessage 

=begin

Exp:

  Class Foo
    include SendMessage
  end

  foo = Foo.new
  foo.add_impression("xx")

=end
