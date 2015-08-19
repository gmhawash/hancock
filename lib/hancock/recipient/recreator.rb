module Hancock
  class Recipient < Hancock::Base
    class Recreator
      attr_reader :docusign_recipient, :tabs

      def initialize(docusign_recipient)
        @docusign_recipient = docusign_recipient

        begin
          @tabs = JSON.parse(docusign_recipient.tabs.body)
        rescue Hancock::Request::RequestError => e
          if e.message.split(' - ')[1] == 'INVALID_RECIPIENT_ID'
            Hancock.logger.error("RECIPIENT RECREATION FAILED PREVIOUSLY, TABS LOST: #{e.message}. RECIPIENT: #{docusign_recipient}")
            # We deleted the recipient without recreating it previously.
            # Probably a connection problem occured to DocuSign.
            # Let this slide, tabs are probably gone T_T
          else
            Hancock.logger.error("ERROR FETCHING RECIPIENT TABS: #{e.message}. RECIPIENT: #{docusign_recipient}")
            raise e
          end
        end
      end

      # Deleting a recipient from an envelope can cause the envelope's status to
      # change. For example, if all other recipients had signed except this one,
      # the envelope status will change to 'complete' when this recipient is
      # deleted, and we will no longer be able to add the recipient back onto the
      # envelope. Hence the placeholder recipient.
      def recreate_with_tabs
        tries ||= 3
        placeholder_docusign_recipient.create

        docusign_recipient.delete
        docusign_recipient.create
        docusign_recipient.create_tabs(tabs) unless tabs.nil? || tabs.empty?

        # loop over any existing placeholders and delete them
        Recipient.fetch_for_envelope(docusign_recipient.envelope_identifier).select do |recipient|
          recipient.email == placeholder_recipient.email
        end.each do |placeholder|
          placeholder.docusign_recipient.delete
        end
      rescue Timeout::Error => e
        if (tries -= 1) > 0
          retry
        else
          Hancock.logger.error("TIMEOUT WHILE RECREATING RECIPIENT: #{e.message}. RECIPIENT: #{docusign_recipient}")
          raise e
        end
      rescue => e
        Hancock.logger.error("ERROR RECREATING RECIPIENT: #{e.message}. RECIPIENT: #{docusign_recipient}")
        raise e
      end

      def placeholder_docusign_recipient
        @placeholder_docusign_recipient ||= DocusignRecipient.new(placeholder_recipient)
      end

      private

      def placeholder_recipient
        Recipient.new(
          :client_user_id      => placeholder_identifier, # Don't send an email
          :identifier          => placeholder_identifier,
          :email               => 'placeholder@example.com',
          :name                => 'Placeholder while recreating recipient',
          :envelope_identifier => docusign_recipient.envelope_identifier,
          :recipient_type      => docusign_recipient.recipient_type,
          :routing_order       => docusign_recipient.routing_order,
          :embedded_start_url  => nil # No really, don't send an email
        )
      end

      def placeholder_identifier
        @placeholder_identifier ||= SecureRandom.uuid
      end
    end
  end
end
