require 'msf/core/post/windows/services'


module Msf
class Post
module Windows

# Based on the research from Tim Tomes and Mark Baggett, at
# http://pauldotcom.com/2011/11/safely-dumping-hashes-from-liv.html
module ShadowCopy

	include Msf::Post::Windows::WindowsServices

	def get_vss_device(id)
		result = get_sc_param(id,'DeviceObject')
	end

	def vss_list
		ids = vss_get_ids
		shadow_copies = []
		ids.each do |id|
			print_status "Getting data for Shadow Copy #{id} (This may take a minute)"
			shadow_copies << get_sc_details("\"#{id}\"")
		end
		return shadow_copies
	end

	def vss_get_ids
		result = wmicexec('shadowcopy get id')
		ids = result.scan(/\{\w{8}-\w{4}-\w{4}-\w{4}-\w{12}\}/)
		return ids
	end

	def vss_get_storage
		storage={}
		storage['AllocatedSpace'] = vss_get_storage_param('AllocatedSpace')
		storage['MaxSpace'] = vss_get_storage_param('MaxSpace')
		storage['UsedSpace'] = vss_get_storage_param('UsedSpace')
		return storage
	end

	def get_sc_details(id)
		shadowcopy={}
		shadowcopy['ID'] = id
		shadowcopy['ClientAccessible'] = get_sc_param(id,'ClientAccessible')
		shadowcopy['Count'] = get_sc_param(id,'Count')
		shadowcopy['DeviceObject'] = get_sc_param(id,'DeviceObject')
		shadowcopy['Differential'] = get_sc_param(id,'Differential')
		shadowcopy['ExposedLocally'] = get_sc_param(id,'ExposedLocally')
		shadowcopy['ExposedName'] = get_sc_param(id,'ExposedName')
		shadowcopy['ExposedRemotely'] = get_sc_param(id,'ExposedRemotely')
		shadowcopy['HardwareAssisted'] = get_sc_param(id,'HardwareAssisted')
		shadowcopy['Imported'] = get_sc_param(id,'Imported')
		shadowcopy['NoAutoRelease'] = get_sc_param(id,'NoAutoRelease')
		shadowcopy['NotSurfaced'] = get_sc_param(id,'Notsurfaced')
		shadowcopy['NoWriters'] = get_sc_param(id,'NoWriters')
		shadowcopy['OriginiatingMachine'] = get_sc_param(id,'OriginatingMachine')
		shadowcopy['Persistent'] = get_sc_param(id,'Persistent')
		shadowcopy['Plex'] = get_sc_param(id,'Plex')
		shadowcopy['ProviderID'] = get_sc_param(id,'ProviderID')
		shadowcopy['ServiceMachine'] = get_sc_param(id,'ServiceMachine')
		shadowcopy['SetID'] = get_sc_param(id,'SetID')
		shadowcopy['State'] = get_sc_param(id,'State')
		shadowcopy['Transportable'] = get_sc_param(id,'Transportable')
		shadowcopy['VolumeName'] = get_sc_param(id,'VolumeName')
		return shadowcopy
	end

	def get_sc_param(id,param_name)
		result = wmicexec("shadowcopy where(id=#{id}) get #{param_name}")
		result.gsub!(param_name,'')
		result.gsub!(/\s/,'')
	end

	def vss_get_storage_param(param_name)
		result = wmicexec("shadowstorage get #{param_name}")
		result.gsub!(param_name,'')
		result.gsub!(/\s/,'')
	end

	def vss_set_storage(bytes)
		result = wmicexec("shadowstorage set MaxSpace=\"#{bytes}\"")
		if result.include?("success")
			return true
		else
			return false
		end
	end

	def create_shadowcopy(volume)
		result = wmicexec("shadowcopy call create \"ClientAccessible\", \"#{volume}\"")
		retval = result.match(/ReturnValue = (\d)/)
		case retval[1].to_i
		when 0
			print_status("ShadowCopy created successfully")
			sc_id = result.match(/ShadowID = ("\{\w{8}-\w{4}-\w{4}-\w{4}-\w{12}\}")/)
			return sc_id[1]
		when 1
			print_error("Access Denied")
		when 2
			print_error("Invalid Argument")
		when 3
			print_error("Specified volume not found")
		when 4
			print_error("Specified volume not supported")
		when 5
			print_error("Unsupported shadow copy context")
		when 6
			print_error("Insufficient Storage")
		when 7
			print_error("Volume is in use")
		when 8
			print_error("Maximum number of shadow copies reached")
		when 9
			print_error("Another shadow copy operation is already in progress")
		when 10
			print_error("Shadow copy provider vetoed the operation")
		when 11
			print_error("Shadow copy provider not registered")
		when 12
			print_error("Shadow copy provider failure")
		else
			print_error("Unknown error")
		end
		return nil
	end

	def start_vss
		vss_state = wmicexec('Service where(name="VSS") get state')
		if vss_state=~ /Running/
			print_status("Volume Shadow Copy service is running.")
		else
			print_status("Volume Shadow Copy service not running. Starting it now...")
			begin
				ss_result = service_start("VSS")
				case ss_result
				when 0
					print_status("Volume Shadow Copy started successfully.")
				when 1
					print_error("Volume Shadow Copy already running.")
				when 2
					print_error("Volume Shadow Copy is disabled.")
					print_status("Attempting to re-enable...")
					service_change_startup("VSS","manual")
					ss_result = service_start("VSS")
					if ss_result == 0
						return true
					else
						return false
					end
				end
			rescue
				print_error("Insufficient Privs to start service!")
				return false
			end
		end
		return true
	end

	def wmicexec(wmiccmd)
		tmpout = ''
		session.response_timeout=120
		begin
			tmp = session.fs.file.expand_path("%TEMP%")
			wmicfl = tmp + "\\"+ sprintf("%.5d",rand(100000))
			r = session.sys.process.execute("cmd.exe /c %SYSTEMROOT%\\system32\\wbem\\wmic.exe /append:#{wmicfl} #{wmiccmd}", nil, {'Hidden' => true})
			sleep(2)
			#Making sure that wmic finishes before executing next wmic command
			prog2check = "wmic.exe"
			found = 0
			while found == 0
				session.sys.process.get_processes().each do |x|
					found =1
					if prog2check == (x['name'].downcase)
						sleep(0.5)
						found = 0
					end
				end
			end
			r.close

			# Read the output file of the wmic commands
			wmioutfile = session.fs.file.new(wmicfl, "rb")
			until wmioutfile.eof?
				tmpout << wmioutfile.read
			end
			wmioutfile.close
		rescue ::Exception => e
			print_error("Error running WMIC commands: #{e.class} #{e}")
		end
		# We delete the file with the wmic command output.
		c = session.sys.process.execute("cmd.exe /c del #{wmicfl}", nil, {'Hidden' => true})
		c.close
		tmpout.gsub!(/[^[:print:]]/,'') #scrub out garbage
		return tmpout
	end


end
end
end
end

