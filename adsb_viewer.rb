#!/usr/bin/env ruby

require 'rubygems'
require 'ncurses'
require 'socket'
require 'adsb'

home_location = nil
if ARGV[1] then
	require 'geokit'
	home_location = GeoKit::LatLng.new(ARGV[0].to_f, ARGV[1].to_f)
end

BOLD_MAX_SECONDS = 60

window = Ncurses.initscr

order_list = []
planes = {}

def add_frame_to_plane_hash(planes, frame)
	time    = frame.time
	icao_id = frame.icao_id.to_s
	if ! planes[icao_id] then
		planes[icao_id] = {}
		planes[icao_id][:icao_id] = icao_id
		planes[icao_id][:contact_times] = []
		planes[icao_id][:position_reports] = []
		planes[icao_id][:track_reports] = []
		planes[icao_id][:country]      = frame.icao_id.country
		planes[icao_id][:country_code] = frame.icao_id.country_code
		planes[icao_id][:contacts] = 0
	end
	if frame.is_a? ADSB::Frame::IdentificationReport then
		planes[icao_id][:identification] = frame.identification
	elsif frame.is_a? ADSB::Frame::PositionReport then
		planes[icao_id][:position_reports] << [ planes[icao_id][:contacts], frame.altitude, frame.lat, frame.lon ]
		# avg. difference in height over the last three reports
		if planes[icao_id][:position_reports].size >=3 then
			diff = 0
			(-3..-2).each do |i|
				diff += planes[icao_id][:position_reports][i+1][1] - planes[icao_id][:position_reports][i][1]
			end
			planes[icao_id][:diff_height] = diff / 3
		end
	elsif frame.is_a? ADSB::Frame::TrackReport then
		planes[icao_id][:track_reports] << [ planes[icao_id][:contacts], frame.velocity, frame.heading, frame.vs ]
	end
	planes[icao_id][:contacts] += 1
	planes[icao_id][:contact_times] << time
end

def info_line(plane, home_location)
	id = plane[:icao_id]
	id = "0"*(6-id.size) + id
	cc = plane[:country_code]
	identification = plane[:identification] || "        "
	position = "                    "
	height = "      "
	distance = "        "
	heading  = "  "
	if plane[:position_reports][-1] then
		lat_formatted = "%02.5f" % [ plane[:position_reports][-1][2] ]
		lon_formatted = "%02.5f" % [ plane[:position_reports][-1][3] ]
		position = "#{lat_formatted}, #{lon_formatted}"
		position = " " * (20 - position.size) + position
		height   = "#{plane[:position_reports][-1][1]}"
		height   = " " * (6 - height.size) + height
		if home_location then
			dist = home_location.distance_to(GeoKit::LatLng.new(plane[:position_reports][-1][2], plane[:position_reports][-1][3]))
			distance = "%3.1f km" % [ dist ]
			distance = " "*(9-distance.size) + distance
			heading  = "%3.0f" % [ home_location.heading_to(GeoKit::LatLng.new(plane[:position_reports][-1][2], plane[:position_reports][-1][3])) ]
		end
	end
	diff_height = " "
	if plane[:diff_height] then
		diff_height = "0" # "↔"
		if plane[:diff_height] > 100 then
			diff_height = "+" # "↑"
		elsif plane[:diff_height] < -100 then
			diff_height = "-" # "↓"
		end
	end
	packets = "#{plane[:contacts]}"
	packets = " "*(3-packets.size) + packets
	last_seen = plane[:contact_times][-1].strftime("%H:%M:%S")
	id + " " + cc + " " + identification + " " + position + " " + height + " " + diff_height + " " + packets + " " + last_seen + distance + " " + heading
end

def draw_line(window, planes, home_location, id, i)
	open '/tmp/log', 'w' do |f|
		f.puts planes.inspect
		f.puts id.inspect
	end
	if (Time.now - planes[id][:contact_times][-1]) < BOLD_MAX_SECONDS then
		# make recent contacts bold
		window.attron(Ncurses::A_BOLD)
	end
	window.mvaddstr(i+1, 0, info_line(planes[id], home_location))
	window.attroff(Ncurses::A_BOLD)
end

def rows_and_cols(window)
	rows, cols = [], []
	window.getmaxyx(rows, cols)
	[rows.first, cols.first]
end

def erase_line(window, i)
	rows, cols = rows_and_cols(window)
	window.mvaddstr(i+1, 0, " "*cols)
end

s = TCPSocket.new 'localhost', 30003

begin
	window.clear
	window.refresh()
	while line = s.gets do
		frame = ADSB::SBS1.parse(line)
		if ! frame then
			open '/tmp/fail.log', 'w' do |f|
				f.puts "Could not parse line: #{line.inspect}"
			end
		end
		next if ! frame
		add_frame_to_plane_hash(planes, frame)
		icao_id = frame.icao_id.to_s
		if ! order_list.include?(icao_id) then
			# a new plane
			order_list = [ icao_id ] + order_list
		end
		window.attroff(Ncurses::A_BOLD)
		if home_location then
			window.mvaddstr(0, 0, "Hex    CC ID          Position           Height    # Seen     Distance" )
		else
			window.mvaddstr(0, 0, "Hex    CC ID          Position           Height    # Seen" )
		end
		index = order_list.index(icao_id)
		if index == 0 then
			# new plane, redraw everything
			order_list.each_with_index do |id, i|
				erase_line(window, i)
				draw_line(window, planes, home_location, id, i)
			end
		else
			# existing plane, just update the corresponding line
			draw_line(window, planes, home_location, icao_id, index)
		end
		window.refresh()
	end
ensure
	Ncurses.endwin
end
