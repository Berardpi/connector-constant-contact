class Entities::Contact < Maestrano::Connector::Rails::Entity

  def self.connec_entity_name
    'Person'
  end

  def self.external_entity_name
    'Contact'
  end

  def self.mapper_class
    ContactMapper
  end

  def before_sync(last_synchronization_date = nil)
    super
    Maestrano::Connector::Rails::ConnectorLogger.log('info', @organization, "Fetching #{Maestrano::Connector::Rails::External.external_name} contact lists")
    all_lists = @external_client.all('List', false)
    Maestrano::Connector::Rails::ConnectorLogger.log('info', @organization, "Received data: Source=#{Maestrano::Connector::Rails::External.external_name}, Entity=contact lists, Response=#{all_lists}")
    extract_specific_lists(all_lists)
  end

  def filter_connec_entities(entities)
    self.class.filter_connec_entities(entities)
  end

  def self.filter_connec_entities(entities)
    entities.reject{|e| e['email'].nil? || e['email'].empty? || e['email']['address'].blank? }
  end

  def get_connec_entities(last_synchronization_date = nil)
    # TODO use Connec! filter when available
    entities = super
    filter_connec_entities(entities)
  end

  def get_external_entities(external_entity_name, last_synchronization_date = nil)
    entities = super

    # Filtering out contact belonging to the employee list as they are employee and not people in Connec!
    # Performance..
    # TODO, do only one call to contact and wrap people and employee in a complex entity
    return entities unless @employee_list
    employee_list_id = @employee_list['id']
    entities.reject { |e| e['lists'].find { |list| list['id'] == employee_list_id && list['status'] == 'ACTIVE' } }
  end

  def self.object_name_from_connec_entity_hash(entity)
    "#{entity['first_name']} #{entity['last_name']}"
  end

  def self.object_name_from_external_entity_hash(entity)
    "#{entity['first_name']} #{entity['last_name']}"
  end

  private
    def extract_specific_lists(all_lists)
      # We could do something smart with some db storage if this is too much of a performance issue
      @customer_list = all_lists.find{|list| list['name'] == 'Customer'}
      @supplier_list = all_lists.find{|list| list['name'] == 'Supplier'}
      @contact_list = all_lists.find{|list| list['name'] == 'Leads and other contacts'} || all_lists.first
      @employee_list = all_lists.find{|list| list['name'] == 'Employee'}
    end
end

class NoteMapper
  extend HashMapper

  map from('id'), to('id')
  map from('description'), to('note')
end

class ContactMapper
  extend HashMapper

  # Mapping to constantcontact
  after_normalize do |input, output, opts|
    if output[:addresses] && !output[:addresses].empty?
      output[:addresses].first.merge!(address_type: 'BUSINESS')
    end

    # Need to specifiy at least one contact list
    lists = []
    lists << {id: opts[:customer_list][:id]} if input['is_customer'] && opts[:customer_list]
    lists << {id: opts[:supplier_list][:id]} if input['is_supplier'] && opts[:supplier_list]
    lists << {id: opts[:contact_list][:id]} if lists.empty?
    lists.uniq!

    output[:lists] = lists

    output
  end

  # Mapping to Connec!
  after_denormalize do |input, output, opts|
    output[:notes] = input['notes'].map{|note| NoteMapper.denormalize(note)} if input['notes']

    output[:opts] = {attach_to_organization: input['company_name']} unless input['company_name'].blank?

    input['lists'].each do |list|
      if opts[:customer_list] && opts[:customer_list][:id] == list['id']
        output[:is_customer] = true
      elsif opts[:supplier_list] && opts[:supplier_list][:id] == list['id']
        output[:is_supplier] = true
        output[:is_customer] ||= false
      elsif opts[:contact_list] && opts[:contact_list][:id] == list['id']
        output[:is_lead] = true
        output[:is_customer] ||= false
      end
    end

    output
  end
  
  map from('first_name'), to('first_name')
  map from('last_name'), to('last_name'), default: 'Undefined'
  map from('title'), to('prefix_name')

  map from('job_title'), to('job_title')

  map from('address_work/billing/line1'), to('addresses[0]/line1')
  map from('address_work/billing/line2'), to('addresses[0]/line2')
  map from('address_work/billing/city'), to('addresses[0]/city')
  map from('address_work/billing/region'), to('addresses[0]/state')
  map from('address_work/billing/postal_code'), to('addresses[0]/postal_code')
  map from('address_work/billing/country'), to('addresses[0]/country_code'){|country|
    c = ISO3166::Country.find_country_by_name(country) || ISO3166::Country.new(country)
    c ? c.alpha2 : ''
  }

  map from('email/address'), to('email_addresses[0]/email_address')

  map from('phone_work/landline'), to('work_phone')
  map from('phone_home/landline'), to('home_phone')
  map from('phone_home/mobile'), to('cell_phone')
  map from('phone_home/fax'), to('fax')
end
