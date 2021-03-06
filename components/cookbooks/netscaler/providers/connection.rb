#
# Cookbook Name:: netscaler
# provider:: connection
#

require 'excon'

def gen_conn(cloud_service,host)
  encoded = Base64.encode64("#{cloud_service[:username]}:#{cloud_service[:password]}").gsub("\n","")
  conn = Excon.new(
    'https://'+host, 
    :headers => {
      'Authorization' => "Basic #{encoded}", 
      'Content-Type' => 'application/x-www-form-urlencoded'
    },
    :ssl_verify_peer => false)
   return conn  
end


def check_for_lbvserver(conn,lbvserver_name)
  resp_obj = JSON.parse(conn.request(
    :method => :get, 
    :path => "/nitro/v1/config/lbvserver/#{lbvserver_name}").body)  
  Chef::Log.info("get lbvserver response: #{resp_obj.inspect}")
  if resp_obj["message"] =~ /No such resource/
    return false
  end
  return true    
end  


def get_connection  
  # return if re-invoked
  if node.has_key?("ns_conn") && !node.ns_conn.nil?
    Chef::Log.info("reusing connection")
    return
  end
  
  cloud_name = node[:workorder][:cloud][:ciName]
  if node[:workorder][:services].has_key?(:lb)
    cloud_service = node[:workorder][:services][:lb][cloud_name][:ciAttributes]
  else
    cloud_service = node[:workorder][:services][:gdns][cloud_name][:ciAttributes]
  end
    
  if node.workorder.has_key?("rfcCi")
    ci = node.workorder.rfcCi
    action = node.workorder.rfcCi.rfcAction
    if node.has_key?("rfcAction")
      action = node.rfcAction
    end
    Chef::Log.info("action: #{action}")
  else
    ci = node.workorder.ci
    action = "action"
  end
  
  az_orig = ci[:ciAttributes][:availability_zone] || ''
  az = ci[:ciAttributes][:availability_zone] || ''
  az_map = JSON.parse(cloud_service[:availability_zones])
  az_ip_range_map = JSON.parse(cloud_service[:az_ip_range_map])
  manifest_ci = node.workorder.payLoad[:RealizedAs].first
  manifest_az = ""
  if !manifest_ci[:ciAttributes][:required_availability_zone].nil?
    manifest_az = manifest_ci[:ciAttributes][:required_availability_zone].gsub(/\s+/,"")
  end    
  
  if !manifest_az.empty?
    az = manifest_az
    if az_orig != az
      puts "***RESULT:availability_zone=#{az}"
    end      
  end
  
  # if az is empty then gen index using manifest id mod az map keys size
  if manifest_az.empty? && (action == "add" || action == "replace")
    index =  manifest_ci[:ciId] % az_map.keys.size
    Chef::Log.info("manifest.Lb ciId: #{manifest_ci[:ciId]} index: #{index}" )  
    az = az_map.keys[index]
    
    # check to see if dc vip is on another netscaler
    existing_az = ""
    found = false
    az_map.keys.each do |check_az|
      host = az_map[check_az]
      conn = gen_conn(cloud_service,host)
      node.dcloadbalancers.each do |lb|
        if check_for_lbvserver(conn,lb[:name]) 
          Chef::Log.info("found existing dc vip: #{lb[:name]} on az: #{check_az} - will use it.")
          az = check_az
          found = true
          break
        end
      end
      break if found
    end
    
    if az_map.has_key?(az)
      node.set["ns_ip_range"] = az_ip_range_map[az]
      Chef::Log.info("using az: #{az} ip_range: #{az_ip_range_map[az]}")   
      host = az_map[az]
      puts "***RESULT:availability_zone=#{az}"
    else
      Chef::Log.error("cloud: #{cloud_name} missing az: #{az}")
      exit 1
    end
  else    
    if az.empty? && action == "delete" && node.workorder.rfcCi.ciBaseAttributes.has_key?("availability_zone")
      Chef::Log.info("delete and changed az to empty - could be via a replace from a specific az to random/maniest id based")
      az = node.workorder.rfcCi.ciBaseAttributes.availability_zone
      Chef::Log.info("using previous az: #{az}")
    end
    if !az_map.has_key?(az) || !az_ip_range_map.has_key?(az)
      Chef::Log.error("invalid az: #{az}")
      exit 1
    end
    host = az_map[az]
    node.set["ns_ip_range"] = az_ip_range_map[az]      
    Chef::Log.info("using az: #{az} ip_range: #{az_ip_range_map[az]}")   
      
  end
  
  # az change
  if node.workorder.has_key?("rfcCi") && 
     node.workorder.rfcCi.ciAttributes.has_key?("required_availability_zone") &&
     node.workorder.rfcCi.ciAttributes.has_key?("availability_zone") &&
     node.workorder.rfcCi.ciAttributes.required_availability_zone != 
       node.workorder.rfcCi.ciAttributes.availability_zone && az_orig != az
  
    host_old = az_map[node.workorder.rfcCi.ciAttributes.availability_zone]
    Chef::Log.info("previous netscaler: #{host_old}")
    node.set["ns_conn_prev"] = gen_conn(cloud_service,host_old)
  end
  
  # ns host
  Chef::Log.info("netscaler: #{host}")
  node.set["ns_conn"] = gen_conn(cloud_service,host)
  node.set["gslb_local_site"] = cloud_service[:gslb_site]
  node.set["netscaler_host"] = host

end  
  
action :create do
   get_connection
end

def load_current_resource
  @current_resource = Chef::Resource::NetscalerConnection.new(@new_resource.name)
end
