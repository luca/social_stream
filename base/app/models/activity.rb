require 'social_stream/dependent_destroyer'

# Activities follow the {Activity Streams}[http://activitystrea.ms/] standard.
#
# == Activities, Contacts and Audiences
# Every activity is attached to a {Contact}, which defines the sender and the receiver of the {Activity}
#
# Besides, the activity is attached to one or more relations, which define the audicence of the activity,
# the {actors Actor} that can reach it and their {permissions Permission}
#
# == Wall
# The Activity.wall(args) scope provides all the activities appearing in a wall
#
# There are two types of wall, :home and :profile. Check {Actor#wall} for more information
#
class Activity < ActiveRecord::Base
  after_create  :increment_like_count
  before_destroy :destroy_children_comments
  after_destroy :decrement_like_count, :delete_notifications
  
  has_ancestry

  paginates_per 10

  belongs_to :activity_verb, :inverse_of => :activities

  belongs_to :contact, :inverse_of => :activities
  
  has_one :sender,   :through => :contact
  
  has_one :receiver, :through => :contact

  has_many :audiences, :inverse_of=>:activity, :dependent => :destroy
  
  has_many :relations, :through => :audiences

  has_many :activity_object_activities,
           :inverse_of=>:activity,
           :dependent => :destroy
           
  has_many :activity_objects,
           :through => :activity_object_activities

  scope :wall, lambda { |args|
    q =
      select("DISTINCT activities.*").
      joins(:contact).
      joins(:audiences).
      joins(:relations).
      roots

    if args[:object_type].present?
      q = q.joins(:activity_objects).
            where('activity_objects.object_type' => args[:object_type])
    end

    contacts   = Contact.arel_table
    audiences  = Audience.arel_table
    relations  = Relation.arel_table

    owner_conditions =
      contacts[:sender_id].eq(Actor.normalize_id(args[:owner])).
        or(contacts[:receiver_id].eq(Actor.normalize_id(args[:owner])))

    audience_conditions =
      audiences[:relation_id].in(args[:relation_ids]).
        or(relations[:type].eq('Relation::Public'))

    conds =
      case args[:type]
      when :home
        followed_conditions =
          contacts[:sender_id].in(args[:followed]).
            or(contacts[:receiver_id].in(args[:followed]))

        owner_conditions.
          or(followed_conditions.and(audience_conditions))
      when :profile
        if args[:for].present?
          visitor_conditions =
            contacts[:sender_id].eq(Actor.normalize_id(args[:for])).
              or(contacts[:receiver_id].eq(Actor.normalize_id(args[:for])))

          owner_conditions.
            and(visitor_conditions.or(audience_conditions))
        else
          owner_conditions.
            and(audience_conditions)
        end
      else
        raise "Unknown wall type: #{ args[:type] }" 
      end

    q.where(conds).
      order("created_at desc")
  }

  before_validation :fill_relations

  after_create  :increment_like_count
  after_destroy :decrement_like_count, :delete_notifications

  validates_presence_of :relations
 
  #For now, it should be the last one
  #FIXME
  after_create :send_notifications

  # The name of the verb of this activity
  def verb
    activity_verb.name
  end

  # Set the name of the verb of this activity
  def verb=(name)
    self.activity_verb = ActivityVerb[name]
  end

  # The {Actor} author of this activity
  #
  # This method provides the {Actor}. Use {#sender_subject} for the {SocialStream::Models::Subject Subject}
  # ({User}, {Group}, etc..)
  def sender
    contact.sender
  end

  # The {SocialStream::Models::Subject Subject} author of this activity
  #
  # This method provides the {SocialStream::Models::Subject Subject} ({User}, {Group}, etc...).
  # Use {#sender} for the {Actor}.
  def sender_subject
    contact.sender_subject
  end

  # The wall where the activity is shown belongs to receiver
  #
  # This method provides the {Actor}. Use {#receiver_subject} for the {SocialStream::Models::Subject Subject}
  # ({User}, {Group}, etc..)
  def receiver
    contact.receiver
  end

  # The wall where the activity is shown belongs to the receiver
  #
  # This method provides the {SocialStream::Models::Subject Subject} ({User}, {Group}, etc...).
  # Use {#receiver} for the {Actor}.
  def receiver_subject
    contact.receiver_subject
  end

  # The comments about this activity
  def comments
    children.includes(:activity_objects).where('activity_objects.object_type' => "Comment")
  end

  # The 'like' qualifications emmited to this activities
  def likes
    children.joins(:activity_verb).where('activity_verbs.name' => "like")
  end

  def liked_by(user) #:nodoc:
    likes.joins(:contact).merge(Contact.sent_by(user))
  end

  # Does user like this activity?
  def liked_by?(user)
    liked_by(user).present?
  end

  # Build a new children activity where subject like this
  def new_like(subject)
    a = children.new :verb => "like",
                     :contact => subject.contact_to!(receiver),
                     :relation_ids => self.relation_ids

    if direct_activity_object.present?
      a.activity_objects << direct_activity_object
    end

    a
  end

  # The first activity object of this activity
  def direct_activity_object
    activity_objects.first
  end

  # The first object of this activity
  def direct_object
    direct_activity_object.try(:object)
  end

  # The title for this activity in the stream
  def title view
    case verb
    when "follow", "make_friend", "like"
      I18n.t "activity.verb.#{ verb }.#{ receiver.subject_type }.title",
      :subject => view.link_name(sender_subject),
      :contact => view.link_name(receiver_subject)
    when "post"
      if sender == receiver
        view.link_name sender_subject
      else
        I18n.t "activity.verb.post.title.other_wall",
               :sender => view.link_name(sender_subject),
               :receiver => view.link_name(receiver_subject)
      end
    end.html_safe
  end

  def notificable?
    is_root? or ['post','update'].include?(root.verb)
  end

  def notify
    return true if !notificable?
    #Avaible verbs: follow, like, make_friend, post, update
    actionview = ActivitiesController.new.view_context

    if ['like','follow','make_friend','post','update'].include? verb and !contact.reflexive?
      notification_subject = actionview.render :partial => 'notifications/activities/' + verb + "_subject", :locals => {:activity => self}
      notification_body = actionview.render :partial =>  'notifications/activities/' + verb + "_body", :locals => {:activity => self}
      receiver.notify(notification_subject, notification_body, self)
    end
    true
  end

  # Is subject allowed to perform action on this {Activity}?
  def allow?(subject, action)
    return false if contact.blank?

    case action
    when 'create'
      return false if contact.sender_id != Actor.normalize_id(subject)

      rels = Relation.normalize(relation_ids)

      own_rels     = rels.select{ |r| r.actor_id == contact.sender_id }
      foreign_rels = rels - own_rels

      # Only posting to own relations or allowed to post to foreign relations
      return foreign_rels.blank? && own_rels.present? ||
             foreign_rels.present? && Relation.allow(subject, 
                                                     action,
                                                     'activity',
                                                     :in => foreign_rels).
                                               all.size == foreign_rels.size

    when 'read'
      return true if relations.select{ |r| r.is_a?(Relation::Public) }.any?

      return false if subject.blank?

      return true if [contact.sender_id, contact.receiver_id].include?(Actor.normalize_id(subject))
    when 'update'
      return true if contact.sender_id == Actor.normalize_id(subject)
    when 'destroy'
      # We only allow destroying to sender and receiver by now
      return [contact.sender_id, contact.receiver_id].include?(Actor.normalize_id(subject))
    end

    Relation.
      allow?(subject, action, 'activity', :in => self.relation_ids, :public => false)
  end

  # Can subject delete the object of this activity?
  def delete_object_by?(subject)
    subject.present? &&
    direct_object.present? &&
      ! direct_object.is_a?(Actor) &&
      ! direct_object.class.ancestors.include?(SocialStream::Models::Subject) &&
      allow?(subject, 'destroy')
  end

  # The {Relation} with which activity is shared
  def audience_in_words(subject, options = {})
    options[:details] ||= :full

    public_relation = relations.select{ |r| r.is_a?(Relation::Public) }

    visibility, audience =
      if public_relation.present?
        [ :public, nil ]
      else
        visible_relations =
          relations.select{ |r| r.actor_id == Actor.normalize_id(subject)}

        if visible_relations.present?
          [ :visible, visible_relations.map(&:name).uniq.join(", ") ]
        else
          [ :hidden, relations.map(&:actor).map(&:name).uniq.join(", ") ]
        end
      end

    I18n.t "activity.audience.#{ visibility }.#{ options[:details] }", :audience => audience
  end

  private

  # Before validation callback
  #
  # Fill the relations when posting to other subject's wall
  def fill_relations
    return if relation_ids.present?

    # FIXME: repeated in SocialStream::Models::Object#_relation_ids
    self.relation_ids =
      if contact.reflexive?
        receiver.relation_customs.map(&:id)
      else
        receiver.relation_customs.allow(contact.sender, 'create', 'activity').map(&:id)
      end
  end

  #Send notifications to actors based on proximity, interest and permissions
  def send_notifications
    notify
  end

  def destroy_children_comments
    comments.each do |c|
      c.direct_object.destroy if c.direct_object
    end
  end

  # after_create callback
  #
  # Increment like counter in objects with a like activity
  def increment_like_count
    return if verb != "like" || direct_activity_object.blank?

    direct_activity_object.increment!(:like_count)
  end

  # after_destroy callback
  #
  # Decrement like counter in objects when like activity is destroyed
  def decrement_like_count
    return if verb != "like" || direct_activity_object.blank?

    direct_activity_object.decrement!(:like_count)
  end
  
  # after_destroy callback
  #
  # Destroy any Notification linked with the activity
  def delete_notifications
    Notification.with_object(self).each do |notification|
      notification.destroy
    end
  end
end
