# Copyright (c) 2010 VMware, Inc.  All Rights Reserved.
require 'trivial_soap'
require 'time'

module RbVmomi

class Boolean; def self.wsdl_name; 'xsd:boolean' end end
class AnyType; def self.wsdl_name; 'xsd:anyType' end end
class Binary; def self.wsdl_name; 'xsd:base64Binary' end end

def self.type name
  fail unless name and (name.is_a? String or name.is_a? Symbol)
  name = $' if name.to_s =~ /^xsd:/
  case name.to_sym
  when :anyType then AnyType
  when :boolean then Boolean
  when :string then String
  when :int, :long, :short, :byte then Integer
  when :float, :double then Float
  when :dateTime then Time
  when :base64Binary then Binary
  else
    if VIM.has_type? name
      VIM.type name
    else
      fail "no such type #{name.inspect}"
    end
  end
end

class DeserializationFailed < Exception; end

class Soap < TrivialSoap
  NS_XSI = 'http://www.w3.org/2001/XMLSchema-instance'

  def initialize opts
    @vim_debug = opts[:vim_debug]
    super opts
    @ns = @opts[:ns] or fail "no namespace specified"
    if @opts[:rev]
      @rev = @opts[:rev]
    elsif @opts[:host]
      @rev = '4.0'
      @rev = serviceContent.about.apiVersion
    end
  end

  def serviceInstance
    VIM::ServiceInstance self, 'ServiceInstance'
  end

  def serviceContent
    @serviceContent ||= serviceInstance.RetrieveServiceContent
  end

  %w(rootFolder propertyCollector searchIndex).map(&:to_sym).each do |s|
    define_method(s) { serviceContent.send s }
  end

  alias root rootFolder

  def emit_request xml, method, descs, this, params
    xml.tag! method, :xmlns => @ns do
      obj2xml xml, '_this', 'ManagedObject', false, this
      descs.each do |d|
        k = d['name'].to_sym
        if params.member? k or params.member? k.to_s
          v = params.member?(k) ? params[k] : params[k.to_s]
          obj2xml xml, d['name'], d['wsdl_type'], d['is-array'], v
        else
          fail "missing required parameter #{d['name']}" unless d['is-optional']
        end
      end
    end
  end

  def parse_response resp, desc
    if resp.at('faultcode')
      detail = resp.at('detail')
      fault = detail && xml2obj(detail.children.first, 'MethodFault')
      msg = resp.at('faultstring').text
      if fault
        raise RbVmomi.fault msg, fault
      else
        fail "#{resp.at('faultcode').text}: #{msg}"
      end
    else
      if desc
        type = desc['is-task'] ? 'Task' : desc['wsdl_type']
        returnvals = resp.children.select(&:element?).map { |c| xml2obj c, type }
        desc['is-array'] ? returnvals : returnvals.first
      else
        nil
      end
    end
  end

  def call method, desc, this, params
    fail "this is not a managed object" unless this.is_a? RbVmomi::VIM::ManagedObject
    fail "parameters must be passed as a hash" unless params.is_a? Hash
    fail unless desc.is_a? Hash

    if @vim_debug
      $stderr.puts "Request #{method}:"
      PP.pp({ _this: this }.merge(params), $stderr)
      $stderr.puts
      start_time = Time.now
    end

    resp = request "#{@ns}/#{@rev}" do |xml|
      emit_request xml, method, desc['params'], this, params
    end

    ret = parse_response resp, desc['result']

    if @vim_debug
      end_time = Time.now
      $stderr.puts "Response (in #{'%.3f' % (end_time - start_time)} s)"
      PP.pp ret, $stderr
      $stderr.puts
    end

    ret
  end

  def demangle_array_type x
    case x
    when 'AnyType' then 'anyType'
    when 'DateTime' then 'dateTime'
    when 'Boolean', 'String', 'Byte', 'Short', 'Int', 'Long', 'Float', 'Double' then x.downcase
    else x
    end
  end

  def xml2obj xml, type
    type = (xml.attribute_with_ns('type', NS_XSI) || type).to_s

    if type =~ /^ArrayOf/
      type = demangle_array_type $'
      return xml.children.select(&:element?).map { |c| xml2obj c, type }
    end

    t = RbVmomi.type type
    if t <= VIM::DataObject
      #puts "deserializing data object #{t} from #{xml.name}"
      props_desc = t.full_props_desc
      h = {}
      props_desc.select { |d| d['is-array'] }.each { |d| h[d['name'].to_sym] = [] }
      xml.children.each do |c|
        next unless c.element?
        field = c.name.to_sym
        #puts "field #{field.to_s}: #{t.find_prop_desc(field.to_s).inspect}"
        d = t.find_prop_desc(field.to_s) or next
        o = xml2obj c, d['wsdl_type']
        if h[field].is_a? Array
          h[field] << o
        else
          h[field] = o
        end
      end
      t.new h
    elsif t == VIM::ManagedObjectReference
      RbVmomi.type(xml['type']).new self, xml.text
    elsif t <= VIM::ManagedObject
      RbVmomi.type(xml['type'] || t.wsdl_name).new self, xml.text
    elsif t <= VIM::Enum
      xml.text
    elsif t <= String
      xml.text
    elsif t <= Symbol
      xml.text.to_sym
    elsif t <= Integer
      xml.text.to_i
    elsif t <= Float
      xml.text.to_f
    elsif t <= Time
      Time.parse xml.text
    elsif t == Boolean
      xml.text == 'true' || xml.text == '1'
    elsif t == Binary
      xml.text.unpack('m')[0]
    elsif t == AnyType
      fail "attempted to deserialize an AnyType"
    else fail "unexpected type #{t.inspect}"
    end
  end

  def obj2xml xml, name, type, is_array, o, attrs={}
    expected = RbVmomi.type(type)
    fail "expected array, got #{o.class.wsdl_name}" if is_array and not o.is_a? Array
    case o
    when Array
      fail "expected #{expected.wsdl_name}, got array" unless is_array
      o.each do |e|
        obj2xml xml, name, expected.wsdl_name, false, e, attrs
      end
    when VIM::ManagedObject
      fail "expected #{expected.wsdl_name}, got #{o.class.wsdl_name} for field #{name.inspect}" if expected and not expected >= o.class
      xml.tag! name, o._ref, :type => o.class.wsdl_name
    when VIM::DataObject
      fail "expected #{expected.wsdl_name}, got #{o.class.wsdl_name} for field #{name.inspect}" if expected and not expected >= o.class
      xml.tag! name, attrs.merge("xsi:type" => o.class.wsdl_name) do
        o.class.full_props_desc.each do |desc|
          if o.props.member? desc['name'].to_sym
            v = o.props[desc['name'].to_sym]
            next if v.nil?
            obj2xml xml, desc['name'], desc['wsdl_type'], desc['is-array'], v
          end
        end
      end
    when VIM::Enum
      xml.tag! name, o.value.to_s, attrs
    when Hash
      fail "expected #{expected.wsdl_name}, got a hash" unless expected <= VIM::DataObject
      obj2xml xml, name, type, false, expected.new(o), attrs
    when true, false
      fail "expected #{expected.wsdl_name}, got a boolean" unless expected == Boolean
      attrs['xsi:type'] = 'xsd:boolean' if expected == AnyType
      xml.tag! name, (o ? '1' : '0'), attrs
    when Symbol, String
      if expected == Binary
        attrs['xsi:type'] = 'xsd:base64Binary' if expected == AnyType
        xml.tag! name, [o].pack('m').chomp, attrs
      else
        attrs['xsi:type'] = 'xsd:string' if expected == AnyType
        xml.tag! name, o.to_s, attrs
      end
    when Integer
      attrs['xsi:type'] = 'xsd:long' if expected == AnyType
      xml.tag! name, o.to_s, attrs
    when Float
      attrs['xsi:type'] = 'xsd:double' if expected == AnyType
      xml.tag! name, o.to_s, attrs
    when DateTime
      attrs['xsi:type'] = 'xsd:dateTime' if expected == AnyType
      xml.tag! name, o.to_s, attrs
    else fail "unexpected object class #{o.class}"
    end
    xml
  end
end

# XXX fault class hierarchy
class Fault < StandardError
  attr_reader :fault

  def initialize msg, fault
    super "#{fault.class.wsdl_name}: #{msg}"
    @fault = fault
  end
end

def self.fault msg, fault
  Fault.new(msg, fault)
end

# host, port, ssl, user, password, path, debug
def self.connect opts
  fail unless opts.is_a? Hash
  fail "host option required" unless opts[:host]
  opts[:user] ||= 'root'
  opts[:password] ||= ''
  opts[:ssl] = true unless opts.member? :ssl
  opts[:port] ||= (opts[:ssl] ? 443 : 80)
  opts[:path] ||= '/sdk'
  opts[:ns] ||= 'urn:vim25'
  opts[:debug] = (!ENV['RBVMOMI_DEBUG'].empty? rescue false) unless opts.member? :debug
  opts[:vim_debug] = (!ENV['RBVMOMI_VIM_DEBUG'].empty? rescue false) unless opts.member? :vim_debug

  Soap.new(opts).tap do |vim|
    vim.serviceContent.sessionManager.Login :userName => opts[:user], :password => opts[:password]
  end
end

end

require 'rbvmomi/types'
vmodl_fn = ENV['VMODL'] || File.join(File.dirname(__FILE__), "../vmodl")
RbVmomi::VIM.load vmodl_fn

require 'rbvmomi/extensions'
