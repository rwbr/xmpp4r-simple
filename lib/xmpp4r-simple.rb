# Jabber::Simple - An extremely easy-to-use Jabber client library.
# Copyright 2006 Blaine Cook <blaine@obvious.com>, Obvious Corp.
# 
# Jabber::Simple is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
# 
# Jabber::Simple is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with Jabber::Simple; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA

require 'time'
require 'rubygems'
require 'xmpp4r'
require 'xmpp4r/roster'
require 'xmpp4r/vcard'
require 'xmpp4r/pubsub'
require 'xmpp4r/pubsub/helper/servicehelper'
require 'xmpp4r/pubsub/helper/nodebrowser'
require 'xmpp4r/pubsub/helper/nodehelper'

module Jabber

  class ConnectionError < StandardError #:nodoc:
  end

  class NotConnected < StandardError #:nodoc:
  end

  class NoPubSubService < StandardError #:nodoc:
  end

  class AlreadySet < StandardError #:nodoc:
  end
  
  module Roster  
    class RosterItem
      def chat_state
        @chat_state
      end
      
      def chat_state=(state)
        @chat_state = state
      end
    end
  end

  class Contact #:nodoc:

    include DRb::DRbUndumped if defined?(DRb::DRbUndumped)

    def initialize(client, jid)
      @jid = jid.respond_to?(:resource) ? jid : JID.new(jid)
      @client = client
    end

    def inspect
      "Jabber::Contact #{jid.to_s}"
    end

    def subscribed?
      [:to, :both].include?(subscription)
    end

    def subscription
      roster_item && roster_item.subscription
    end

    def ask_for_authorization!
      subscription_request = Presence.new.set_type(:subscribe)
      subscription_request.to = jid
      client.send!(subscription_request)
    end
    
    def unsubscribe!
      unsubscription_request = Presence.new.set_type(:unsubscribe)
      unsubscription_request.to = jid
      client.send!(unsubscription_request)
      client.send!(unsubscription_request.set_type(:unsubscribed))
    end

    def jid(bare=true)
      bare ? @jid.strip : @jid
    end

    private

    def roster_item
      client.roster.items[jid]
    end
   
    def client
      @client
    end
  end

  class Simple

    include DRb::DRbUndumped if defined?(DRb::DRbUndumped)

    # Create a new Jabber::Simple client. You will be automatically connected
    # to the Jabber server and your status message will be set to the string
    # passed in as the status_message argument.
    #
    # jabber = Jabber::Simple.new("me@example.com", "password", nil, "Chat with me - Please!")
    def initialize(jid, password, status = nil, status_message = "Available", host = nil, port = 5222)
      @jid = jid
      @password = password
      @host = host
      @port = port
      @disconnected = false
      status(status, status_message)
      start_deferred_delivery_thread
      
      @pubsub = @pubsub_jid = nil
      begin
        domain = Jabber::JID.new(@jid).domain
        @pubsub_jid = "pubsub." + domain
        set_pubsub_service(@pubsub_jid)
      rescue
        @pubsub = @pubsub_jid = nil
      end
    end

    def inspect #:nodoc:
      "Jabber::Simple #{@jid}"
    end
    
    # Send a message to jabber user jid.
    # It is possible to send message to multiple users at once,
    # just supply array of jids.
    #
    # Example usage:
    #
    #   jabber_simple.deliver("foo@example.com", "blabla")
    #   jabber_simple.deliver(["foo@example.com", "bar@example.com"], "blabla")
    #
    # Valid message types are:
    # 
    #   * :normal (default): a normal message.
    #   * :chat: a one-to-one chat message.
    #   * :groupchat: a group-chat message.
    #   * :headline: a "headline" message.
    #   * :error: an error message.
    #
    # If the recipient is not in your contacts list, the message will be queued
    # for later delivery, and the Contact will be automatically asked for
    # authorization (see Jabber::Simple#add).
    #
    # message should be a string or a valid Jabber::Message object. In either case,
    # the message recipient will be set to jid.
    def deliver(jids, message, type = :chat, chat_state = :active)
      contacts(jids) do |friend|
        unless subscribed_to? friend
          add(friend.jid)
          deliver_deferred(friend.jid, message, type)
          next
        end
        if message.kind_of?(Jabber::Message)
          msg = message
          msg.to = friend.jid
        else
          msg = Message.new(friend.jid)
          msg.type = type
          msg.chat_state = chat_state
          msg.body = message
        end
        send!(msg)
      end
    end

    # Set your presence, with a message.
    #
    # Available values for presence are:
    # 
    #   * nil: online.
    #   * :chat: free for chat.
    #   * :away: away from the computer.
    #   * :dnd: do not disturb.
    #   * :xa: extended away.
    #
    # It's not possible to set an offline status - to do that, disconnect! :-)
    def status(presence, message)
      @presence = presence
      @status_message = message
      stat_msg = Presence.new(@presence, @status_message)

      if !avatar_hash.nil?
        x = Jabber::X.new
        x.add_namespace('vcard-temp:x:update')
        photo = REXML::Element::new("photo")
        photo.add(REXML::Text.new(avatar_hash))
        x.add(photo)
        stat_msg.add_element(x)
      end
      
      send!(stat_msg)
    end

    # Ask the users specified by jids for authorization (i.e., ask them to add
    # you to their contact list). If you are already in the user's contact list,
    # add() will not attempt to re-request authorization. In order to force
    # re-authorization, first remove() the user, then re-add them.
    #
    # Example usage:
    # 
    #   jabber_simple.add("friend@friendosaurus.com")
    #
    # Because the authorization process might take a few seconds, or might
    # never happen depending on when (and if) the user accepts your
    # request, results are placed in the Jabber::Simple#new_subscriptions queue.
    def add(*jids)
      contacts(*jids) do |friend|
        next if subscribed_to? friend
        friend.ask_for_authorization!
      end
    end

    # Remove the jabber users specified by jids from the contact list.
    def remove(*jids)
      contacts(*jids) do |unfriend|
        unfriend.unsubscribe!
      end
    end

    # Returns true if this Jabber account is subscribed to status updates for
    # the jabber user jid, false otherwise.
    def subscribed_to?(jid)
      contacts(jid) do |contact|
        return contact.subscribed?
      end
    end

    # Returns array of roster items.
    def contact_list
      roster.items.values
    end
    
    # Retrieve vCard of an entity
    #
    # Raises exception upon retrieval error, please catch that!
    #
    # Usage of Threads is suggested here as vCards can be very
    # big.
    #
    # jid:: [Jabber::JID] or nil (should be stripped, nil for the client's own vCard)
    # result:: [Jabber::IqVcard] or nil (nil results may be handled as empty vCards)
    def get_info(jid = nil)
      Jabber::Vcard::Helper.new(client).get(jid)
    end
    
    # Update your own vCard
    #
    # Raises exception when setting fails
    #
    # Usage of Threads suggested here, too. The function
    # waits for approval from the server.
    # e.g.:
    #
    #   info =  Jabber::Vcard::IqVcard.new
    #   info["NICKNAME"] = "amay"
    #   jabber.update_info(info)
    def update_info(vcard)
      Jabber::Vcard::Helper.new(client).set(vcard)
    end
    
    # Returns SHA1 hash of the avatar image data.
    #
    # This hash is then included in the user's presence information.
    def avatar_hash
      vcard = get_info
      if !vcard.nil? && !vcard["PHOTO/BINVAL"].nil?
        Digest::SHA1.hexdigest(Base64.decode64(vcard["PHOTO/BINVAL"]))
      else
        nil
      end
    end

    # Returns true if the Jabber client is connected to the Jabber server,
    # false otherwise.
    def connected?
      @client ||= nil
      connected = @client.respond_to?(:is_connected?) && @client.is_connected?
      return connected
    end

    # Returns an array of messages received since the last time
    # received_messages was called. Passing a block will yield each message in
    # turn, allowing you to break part-way through processing (especially
    # useful when your message handling code is not thread-safe (e.g.,
    # ActiveRecord).
    #
    # e.g.:
    #
    #   jabber.received_messages do |message|
    #     puts "Received message from #{message.from}: #{message.body}"
    #   end
    def received_messages(&block)
      dequeue(:received_messages, &block)
    end

    # Returns true if there are unprocessed received messages waiting in the
    # queue, false otherwise.
    def received_messages?
      !queue(:received_messages).empty?
    end

    # Returns an array of iq stanzas received since the last time
    # iq_stanzas was called. There will be no stanzas in this queue
    # unless you have enabled capture of <iq/> stanzas using the
    # capture_iq_stanzas! method. Passing a block will yield each stanza in
    # turn, allowing you to break part-way through processing (especially
    # useful when your message handling code is not thread-safe (e.g.,
    # ActiveRecord).
    #
    # e.g.:
    #
    #   jabber.capture_iq_stanzas!
    #   jabber.iq_stanzas do |iq|
    #     puts "Received iq stanza from #{iq.from}"
    #   end
    def iq_stanza(&block)
      dequeue(:iq_stanzas, &block)
    end

    # Returns true if there are unprocessed iq stanzas waiting in the
    # queue, false otherwise.
    def iq_stanzas?
      !queue(:iq_stanzas).empty?
    end

    # Tell the client to capture (or stop capturing) <iq/> stanzas
    # addressed to it.  When the client is initially started, this
    # is false.
    def capture_iq_stanzas!(capture=true)
      @iq_mutex.synchronize { @capture_iq_stanzas = capture }
    end
    
    # Returns true if iq stanzas will be captured in the queue, as
    # they arrive, false otherwise.
    def capture_iq_stanzas?
      @capture_iq_stanzas
    end

    # Returns an array of presence updates received since the last time
    # presence_updates was called. Passing a block will yield each update in
    # turn, allowing you to break part-way through processing (especially
    # useful when your presence handling code is not thread-safe (e.g.,
    # ActiveRecord).
    #
    # e.g.:
    #
    #   jabber.presence_updates do |friend, new_presence|
    #     puts "Received presence update from #{friend}: #{new_presence}"
    #   end
    def presence_updates(&block)
      updates = []
      @presence_mutex.synchronize do
        dequeue(:presence_updates) do |friend|
          presence = @presence_updates[friend]
          next unless presence
          new_update = [friend, presence[0], presence[1]]
          yield new_update if block_given?
          updates << new_update
          @presence_updates.delete(friend)
        end
      end
      return updates
    end
    
    # Returns true if there are unprocessed presence updates waiting in the
    # queue, false otherwise.
    def presence_updates?
      !queue(:presence_updates).empty?
    end

    # Returns an array of subscription notifications received since the last
    # time new_subscriptions was called. Passing a block will yield each update
    # in turn, allowing you to break part-way through processing (especially
    # useful when your subscription handling code is not thread-safe (e.g.,
    # ActiveRecord).
    #
    # e.g.:
    #
    #   jabber.new_subscriptions do |friend, presence|
    #     puts "Received presence update from #{friend.to_s}: #{presence}"
    #   end
    def new_subscriptions(&block)
      dequeue(:new_subscriptions, &block)
    end
    
    # Returns true if there are unprocessed presence updates waiting in the
    # queue, false otherwise.
    def new_subscriptions?
      !queue(:new_subscriptions).empty?
    end
    
    # Returns an array of subscription notifications received since the last
    # time subscription_requests was called. Passing a block will yield each update
    # in turn, allowing you to break part-way through processing (especially
    # useful when your subscription handling code is not thread-safe (e.g.,
    # ActiveRecord).
    #
    # e.g.:
    #
    #   jabber.subscription_requests do |friend, presence|
    #     puts "Received presence update from #{friend.to_s}: #{presence}"
    #   end
    def subscription_requests(&block)
      dequeue(:subscription_requests, &block)
    end

    # Returns true if auto-accept subscriptions (friend requests) is enabled
    # (default), false otherwise.
    def accept_subscriptions?
      @accept_subscriptions = true if @accept_subscriptions.nil?
      @accept_subscriptions
    end

    # Change whether or not subscriptions (friend requests) are automatically accepted.
    def accept_subscriptions=(accept_status)
      @accept_subscriptions = accept_status
    end
    
    # Direct access to the underlying Roster helper.
    def roster
      return @roster if @roster
      self.roster = Roster::Helper.new(client)
    end

    # Direct access to the underlying Jabber client.
    def client
      connect!() unless connected?
      @client
    end
    
    # Send a Jabber stanza over-the-wire.
    def send!(msg)
      attempts = 0
      begin
        attempts += 1
        client.send(msg)
      rescue Errno::EPIPE, IOError => e
        sleep 1
        disconnect
        reconnect
        retry unless attempts > 3
        raise e
      rescue Errno::ECONNRESET => e
        sleep (attempts^2) * 60 + 60
        disconnect
        reconnect
        retry unless attempts > 3
        raise e
      end
    end

    # Use this to force the client to reconnect after a force_disconnect.
    def reconnect
      @disconnected = false
      connect!
    end

    # Use this to force the client to disconnect and not automatically
    # reconnect.
    def disconnect
      disconnect!
    end
    
    # Queue messages for delivery once a user has accepted our authorization
    # request. Works in conjunction with the deferred delivery thread.
    #
    # You can use this method if you want to manually add friends and still
    # have the message queued for later delivery.
    def deliver_deferred(jid, message, type)
      msg = {:to => jid, :message => message, :type => type}
      queue(:pending_messages) << [msg]
    end

    # Checks if the PubSub service is set
    def has_pubsub?
      ! @pubsub.nil?
    end

    # Sets the PubSub service. Just one service is allowed.
    def set_pubsub_service(service)
      raise NotConnected, "You are not connected" if @disconnected
      raise AlreadySet, "You already have a PubSub service. Currently it's not allowed to have more." if has_pubsub?
      @pubsub = PubSub::ServiceHelper.new(@client, service)
      @pubsub_jid = service

      @pubsub.add_event_callback do |event|
        queue(:received_events) << event
      end
    end

    # Subscribe to a node.
    def pubsubscribe_to(node)
      raise NoPubSubService, "Have you forgot to call #set_pubsub_service ?" if ! has_pubsub?
      @pubsub.subscribe_to(node)
    end

    # Unsubscribe from a node.
    def pubunsubscribe_from(node)
      raise NoPubSubService, "Have you forgot to call #set_pubsub_service ?" if ! has_pubsub?

      # FIXME
      # @pubsub.unsubscribe_from(node)
      # ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      # The above should just work, but I had to reimplement it since XMPP4R doesn't support subids
      # and OpenFire (the Jabber Server I am testing against) seems to require it.

      subids = find_subids_for(node)
      return if subids.empty?

      subids.each do |subid|
        iq = Jabber::Iq.new(:set, @pubsub_jid)
        iq.add(Jabber::PubSub::IqPubSub.new)
        iq.from = @jid
        unsub = REXML::Element.new('unsubscribe')
        unsub.attributes['node'] = node
        unsub.attributes['jid'] = @jid
        unsub.attributes['subid'] = subid
        iq.pubsub.add(unsub)
        res = nil
        @client.send_with_id(iq) do |reply|
          res = reply.kind_of?(Jabber::Iq) and reply.type == :result
        end # @stream.send_with_id(iq)
      end
    end

    # Return the subscriptions we have in the configured PubSub service.
    def pubsubscriptions
      raise NoPubSubService, "Have you forgot to call #set_pubsub_service ?" if ! has_pubsub?
      @pubsub.get_subscriptions_from_all_nodes()
    end

    # Just like #received_messages, but for PubSub events
    def received_events(&block)
      dequeue(:received_events, &block)
    end

    # Returns true if there are unprocessed received events waiting in the
    # queue, false otherwise.
    def received_events?
      !queue(:received_events).empty?
    end

    # Create a PubSub node (Lots of options still have to be encoded!)
    def create_node(node)
      raise NoPubSubService, "Have you forgot to call #set_pubsub_service ?" if ! has_pubsub?
      @pubsub.create_node(node)
    end

    # Return an array of nodes I own
    def my_nodes
      ret = []
      pubsubscriptions.each do |sub|
        ret << sub.node if sub.attributes['affiliation'] == 'owner'
      end
      return ret
    end

    # Delete a PubSub node (Lots of options still have to be encoded!)
    def delete_node(node)
      raise NoPubSubService, "Have you forgot to call #set_pubsub_service ?" if ! has_pubsub?
      @pubsub.delete_node(node)
    end

    # Publish an Item. This infers an item of Jabber::PubSub::Item kind is passed
    def publish_item(node, item)
      raise NoPubSubService, "Have you forgot to call #set_pubsub_service ?" if ! has_pubsub?
      @pubsub.publish_item_to(node, item)
    end

    # Publish Simple Item. This is an item with one element and some text to it.
    def publish_simple_item(node, text)
      raise NoPubSubService, "Have you forgot to call #set_pubsub_service ?" if ! has_pubsub?

      item = Jabber::PubSub::Item.new
      xml = REXML::Element.new('value')
      xml.text = text
      item.add(xml)
      publish_item(node, item)
    end

    # Publish atom Item. This is an item with one atom entry with title, body and time.
    def publish_atom_item(node, title, body, time = Time.now)
      raise NoPubSubService, "Have you forgot to call #set_pubsub_service ?" if ! has_pubsub?

      item = Jabber::PubSub::Item.new
      entry = REXML::Element.new('entry')
      entry.add_namespace("http://www.w3.org/2005/Atom")
      mytitle = REXML::Element.new('title')
      mytitle.text = title
      entry.add(mytitle)
      mybody = REXML::Element.new('body')
      mybody.text = body
      entry.add(mybody)
      published = REXML::Element.new("published")
      published.text = time.utc.iso8601
      entry.add(published)
      item.add(entry)
      publish_item(node, item)
    end

    private
    
    # If contacts is a single contact, returns a Jabber::Contact object
    # representing that user; if contacts is an array, returns an array of
    # Jabber::Contact objects.
    #
    # When called with a block, contacts will yield each Jabber::Contact object
    # in turn. This is used internally.
    def contacts(*contacts, &block)
      contacts.flatten!
      @contacts ||= {}
      contakts = []
      contacts.each do |contact|
        jid = contact.to_s
        unless @contacts[jid]
          @contacts[jid] = contact.respond_to?(:ask_for_authorization!) ? contact : Contact.new(self, contact)
        end
        yield @contacts[jid] if block_given?
        contakts << @contacts[jid]
      end
      contakts.size > 1 ? contakts : contakts.first
    end

    def find_subids_for(node)
      ret = []
      pubsubscriptions.each do |subscription|
        if subscription.node == node
          ret << subscription.subid
        end
      end
      return ret
    end

    def client=(client)
      self.roster = nil # ensure we clear the roster, since that's now associated with a different client.
      @client = client
    end

    def roster=(new_roster)
      @roster = new_roster
    end

    def connect!
      raise ConnectionError, "Connections are disabled - use Jabber::Simple::force_connect() to reconnect." if @disconnected
      # Pre-connect
      @connect_mutex ||= Mutex.new

      # don't try to connect if another thread is already connecting.
      return if @connect_mutex.locked?

      @connect_mutex.lock
      disconnect!(false) if connected?

      # Connect
      jid = JID.new(@jid)
      my_client = Client.new(@jid)
      my_client.connect(@host, @port)
      my_client.auth(@password)
      self.client = my_client

      # Post-connect
      register_default_callbacks
      status(@presence, @status_message)
      @connect_mutex.unlock
    end

    def disconnect!(auto_reconnect = true)
      if client.respond_to?(:is_connected?) && client.is_connected?
        begin
          client.close
        rescue Errno::EPIPE, IOError => e
          # probably should log this.
          nil
        end
      end
      client = nil
      @disconnected = auto_reconnect
    end

    def register_default_callbacks
      client.add_message_callback do |message|
        queue(:received_messages) << message unless message.body.nil?
        from = roster.find(message.from).values.first
        if !message.chat_state.nil? && from.chat_state != message.chat_state
          from.chat_state = message.chat_state
        end
      end

      roster.add_subscription_callback do |roster_item, presence|
        if presence.type == :subscribed
          queue(:new_subscriptions) << [roster_item, presence]
        end
      end

      roster.add_subscription_request_callback do |roster_item, presence|
        if accept_subscriptions?
          roster.accept_subscription(presence.from) 
        else
          queue(:subscription_requests) << [roster_item, presence]
        end
      end

      @iq_mutex = Mutex.new
      capture_iq_stanzas!(false)
      client.add_iq_callback do |iq|
        queue(:iq_messages) << iq if capture_iq_stanzas?
      end

      @presence_updates = {}
      @presence_mutex = Mutex.new
      roster.add_presence_callback do |roster_item, old_presence, new_presence|
        simple_jid = roster_item.jid.strip.to_s
        presence = case new_presence.type
                   when nil then new_presence.show || :online
                   when :unavailable then :unavailable
                   else
                     nil
                   end

        if presence && @presence_updates[simple_jid] != presence
          queue(:presence_updates) << simple_jid
          @presence_mutex.synchronize { @presence_updates[simple_jid] = [presence, new_presence.status] }
        end
      end
    end

    # This thread facilitates the delivery of messages to users who haven't yet
    # accepted an invitation from us. When we attempt to deliver a message, if
    # the user hasn't subscribed, we place the message in a queue for later
    # delivery. Once a user has accepted our authorization request, we deliver
    # any messages that have been queued up in the meantime.
    def start_deferred_delivery_thread #:nodoc:
      Thread.new {
        loop {
          messages = [queue(:pending_messages).pop].flatten
          messages.each do |message|
            if subscribed_to?(message[:to])
              deliver(message[:to], message[:message], message[:type])
            else
              queue(:pending_messages) << message
            end
          end
          sleep 60
        }
      }
    end

    def queue(queue)
      @queues ||= Hash.new { |h,k| h[k] = Queue.new }
      @queues[queue]
    end

    def dequeue(queue, non_blocking = true, max_items = 100, &block)
      queue_items = []
      max_items.times do
        break if queue(queue).empty?
        queue_item = queue(queue).pop(non_blocking)
        queue_items << queue_item
        yield queue_item if block_given?
      end
      queue_items
    end
  end
end

true
