# The program handles the KAP chart files and BSB files
#
# Author::    Pavel Kalian  (mailto:pavel@kalian.cz)
# Copyright:: Copyright (c) 2011 Pavel Kalian
# Portions from gc.rb script Copyright (C) 2009 by Thomas Hockne
# License::   Distributes under the terms of GPLv2 or later

if (RUBY_VERSION.start_with?("1.9"))
  require "Mysql"
else
  require "mysql"
end
require "optparse"
require "./util.rb"
require "./bsb.rb"
require "./kap.rb"
require "./ellipsoid.rb"
require "./projection.rb"

require "./config.rb"


# This class represents a single paper chart
class Chart
  # Chart number
  attr_accessor :number
  # BSB file representing the chart
  attr_accessor :bsb
  # array of KAPs representing the chart
  attr_accessor :kaps
  # Chart rotated by multiple of 90 degrees has to be preprocessed to be north-up
  attr_accessor :pre_rotate
  # Size of the corner cut-out in pixels (defaults to 1500)
  attr_accessor :corner_size
  
  # Default constructor
  def initialize
    @kaps = Array.new
    @pre_rotate = 0
    @corner_size = 1500
  end

  # Generates the 'BASE' KAPs for all the newly calibrated charts
  def Chart.process_new_base_calibrations
    res = $dbh.query("SELECT number FROM ocpn_nga_charts_with_params WHERE status_id IN (1, 2, 3, 8, 14, 18) AND kap_generated IS NULL AND North IS NOT NULL AND South IS NOT NULL AND East IS NOT NULL AND West IS NOT NULL AND Xsw IS NOT NULL AND Ysw IS NOT NULL AND Xnw IS NOT NULL AND Ynw IS NOT NULL AND Xne IS NOT NULL AND Yne AND Xse IS NOT NULL AND Yse IS NOT NULL")

    while row = res.fetch_hash do
      puts "Processing chart #{row["number"]}"
      chart = Chart.new
      chart.produce(row["number"], $kap_size_percent, $kap_autorotate)
    end
  end
  
  # Generates the 'BASE' KAPs for all the newly calibrated charts
  def Chart.process_new_insets
    $dbh.query("DELETE FROM ocpn_nga_kap WHERE number NOT IN (SELECT number FROM ocpn_nga_charts)") #Clean the bad user input
    $dbh.query("DELETE FROM ocpn_nga_kap_point WHERE kap_id NOT IN (SELECT kap_id FROM ocpn_nga_kap)")
    $dbh.query("DELETE FROM ocpn_nga_kap_point WHERE point_type='CROP' AND active = 1 AND kap_id IN(SELECT kap_id FROM (SELECT kap_id, MAX(x) AS xm, MAX(y) AS ym FROM ocpn_nga_kap_point WHERE active = 1 GROUP BY kap_id) t WHERE t.xm = 0 AND t.ym = 0)")
    
    res = $dbh.query("SELECT DISTINCT number FROM ocpn_nga_kap WHERE active=1 AND kap_id IN (SELECT kap_id FROM ocpn_nga_kap_point WHERE active=1 AND point_type = 'CROP') AND cropped IS NULL")

    while row = res.fetch_hash do
      puts "Processing insets in chart #{row["number"]}"
      chart = Chart.new
      chart.crop_insets(row["number"])
    end
  end
    
  # Loads the chart from the database
  # TODO: Now it simplifies everything for testing and has to be rewritten for real world use
  def load_from_db #TODO - now we load it simply for phase 1 - from the view, has to be redone to actually work well
    res = $dbh.query("SELECT * FROM ocpn_nga_charts_with_params WHERE number=#{@number}")

    while row = res.fetch_hash do
      #puts row.inspect
      @pre_rotate = row["prerotate"].to_i
      @corner_size = row["cornersize"].to_i
      @bsb = BSB.new
      @bsb.comment = "!This chart originates from
!http://www.nauticalcharts.noaa.gov/mcd/OnLineViewer.html
!DO NOT USE FOR NAVIGATION
!Use official, full scale nautical charts for real-world navigation.
!These are available from authorized nautical chart sales agents.
!Screen captures of the charts available here do NOT fulfill chart
!carriage requirements for regulated commercial vessels under
!Titles 33 and 46 of the Code of Federal Regulations."
      @bsb.ver = "2.0"
      @bsb.crr = "This chart is released by the OpenCPN.info - NGA chart project."
      @bsb.cht_na = row["title"]
      @bsb.cht_nu = row["number"]
      @bsb.chf = row["bsb_chf"]
      @bsb.org = "NGA"
      @bsb.mfr = "NGA chart project"
      @bsb.cgd = 0
      @bsb.ced_se = row["date"] #row["edition"]
      @bsb.ced_re = 1 #TODO - parameter of our process
      @bsb.ced_ed = 1 #TODO - parameter of our process
      @bsb.ntm_ne = row["edition"]
      @bsb.ntm_nd = row["correction"]
      @bsb.ntm_bf = "UNKNOWN"
      @bsb.ntm_bd = "UNKNOWN"
      
      ki = KAPinfo.new
      ki.idx = @bsb.kap.length + 1
      ki.na = row["title"]
      ki.nu = row["number"]
      ki.ty = row["bsb_type"]
      ki.fn = row["number"] + ".kap"
      @bsb.kap << ki
      @bsb.chk = @bsb.kap.length
      
      kap = KAPHeader.new
      kap.comment = "!This chart originates from
!http://www.nauticalcharts.noaa.gov/mcd/OnLineViewer.html
!DO NOT USE FOR NAVIGATION
!Use official, full scale nautical charts for real-world navigation.
!These are available from authorized nautical chart sales agents.
!Screen captures of the charts available here do NOT fulfill chart
!carriage requirements for regulated commercial vessels under
!Titles 33 and 46 of the Code of Federal Regulations."
      kap.ver = "2.0"
      kap.crr = "This chart is released by the OpenCPN.info - NGA chart project."
      kap.bsb_na = row["title"]
      kap.bsb_nu = row["number"]
      if (@pre_rotate != 90 && @pre_rotate != 270)
        kap.bsb_ra = [row["width"].to_i, row["height"].to_i]
      else
        kap.bsb_ra = [row["height"].to_i, row["width"].to_i]
      end
      kap.bsb_du = 72 # TODO - Will we bother with the DPI claculation?
      
      kap.ced_se = row["date"] #row["edition"]
      kap.ced_re = 1 #TODO - parameter of our process
      kap.ced_ed = 1 #TODO - parameter of our process
      
      kap.knp_sc = row["scale"]
      kap.knp_gd = row["GD"] # should be used in case we don't have a datum for plotting available - it's handled by compute_gd later
      kap.knp_pr = row["PR"]
      kap.knp_pp = row["PP"]
      kap.knp_pi = "UNKNOWN"
      kap.knp_sk = 0.0 #TODO - generally we do not want the skewed charts, but...
      kap.knp_ta = 90.0 # probably true for all the charts 
      kap.knp_un = row["UN"]
      kap.knp_sd = row["SD"]
      kap.knp_sp = "UNKNOWN"

      kap.dtm = [-1 * row["DTMy"].to_f * 60, -1 * row["DTMx"].to_f * 60] #convert to seconds and reverse the sign
      if (kap.dtm[0] == -0.0) then kap.dtm[0] = 0.0 end
      if (kap.dtm[1] == -0.0) then kap.dtm[1] = 0.0 end
      kap.dtm_dat = row["DTMdat"]
      kap.ifm = 5 #TODO - parameter of our process
      kap.ost = 1
      
      sw = REF.new
      sw.idx = 1
      sw.x = row["Xsw"].to_i
      sw.y = row["Ysw"].to_i
      sw.latitude = row["South"].to_f
      sw.longitude = row["West"].to_f
      kap.ref << sw
      
      nw = REF.new
      nw.idx = 2
      nw.x = row["Xnw"].to_i
      nw.y = row["Ynw"].to_i
      nw.latitude = row["North"].to_f
      nw.longitude = row["West"].to_f
      kap.ref << nw
      
      ne = REF.new
      ne.idx = 3
      ne.x = row["Xne"].to_i
      ne.y = row["Yne"].to_i
      ne.latitude = row["North"].to_f
      ne.longitude = row["East"].to_f
      kap.ref << ne
      
      se = REF.new
      se.idx = 4
      se.x = row["Xse"].to_i
      se.y = row["Yse"].to_i
      se.latitude = row["South"].to_f
      se.longitude = row["East"].to_f
      kap.ref << se
      
      #TODO: this of course has to be elsewhere, there just because we made it easy and don't count with composite charts
      res = $dbh.query("SELECT sequence, latitude, longitude FROM ocpn_nga_kap_point WHERE active = 1 AND point_type = 'PLY' AND kap_id IN (SELECT kap_id FROM ocpn_nga_kap WHERE  bsb_type = 'BASE' AND number = #{@number}) ORDER BY sequence")

      while row = res.fetch_hash do
        ply = PLY.new
        ply.idx = row["sequence"].to_i
        ply.latitude = row["latitude"].to_f
        ply.longitude = row["longitude"].to_f
        kap.ply << ply
      end
      
      #when polygon is less than a triangle...
      if kap.ply.length < 3
        kap.ply.clear #clear the (we think erroneous PLY points)
        kap.ply << sw.to_PLY
        kap.ply << nw.to_PLY
        kap.ply << ne.to_PLY
        kap.ply << se.to_PLY
      end
      
      if (kap.knp_pp == nil) then kap.compute_pp end
      kap.compute_cph
      kap.compute_gd
      kap.compute_dxdy
      
      @kaps << kap
    end

    res.free
#    $dbh.query("UPDATE ocpn_nga_kap SET kap_generated = CURRENT_TIMESTAMP() WHERE bsb_type = 'BASE' AND number=#{@number}")
  end
  
  
  # Generates corner cut-outs for the chart the chart
  # The chart has to be preprocessed already, the rotation is not done as part of this process
  def generate_corners(number)
    jpg_path = $jpg_path.gsub("{CHART_NUMBER}", number.to_s)
    preprocessed_jpg_path = $preprocessed_jpg_path.gsub("{CHART_NUMBER}", number.to_s)
    
    res = $dbh.query("SELECT * FROM ocpn_nga_charts WHERE number=#{number}")

    while row = res.fetch_hash do
      puts "Generating corners for chart #{row["number"]}"
      
      # If rotated, use preprocessed JPG
      if (row["prerotate"].to_i != 0)
        jpg = preprocessed_jpg_path
      else
        jpg = jpg_path
      end
      # create corner cut-outs
      corner_size = row["cornersize"]
      corner_path = $corner_path.gsub("{CHART_NUMBER}", number.to_s).gsub("{INSET}", "").gsub("{CORNER}", 'sw')
      `#{$convert_command} #{jpg} -gravity SouthWest -crop #{corner_size}x#{corner_size}+0+0 -depth 8 -type Palette -colors 32 png8:#{corner_path}`
      corner_path = $corner_path.gsub("{CHART_NUMBER}", number.to_s).gsub("{INSET}", "").gsub("{CORNER}", 'nw')
      `#{$convert_command} #{jpg} -gravity NorthWest -crop #{corner_size}x#{corner_size}+0+0 -depth 8 -type Palette -colors 32 png8:#{corner_path}`
      corner_path = $corner_path.gsub("{CHART_NUMBER}", number.to_s).gsub("{INSET}", "").gsub("{CORNER}", 'ne')
      `#{$convert_command} #{jpg} -gravity NorthEast -crop #{corner_size}x#{corner_size}+0+0 -depth 8 -type Palette -colors 32 png8:#{corner_path}`
      corner_path = $corner_path.gsub("{CHART_NUMBER}", number.to_s).gsub("{INSET}", "").gsub("{CORNER}", 'se')
      `#{$convert_command} #{jpg} -gravity SouthEast -crop #{corner_size}x#{corner_size}+0+0 -depth 8 -type Palette -colors 32 png8:#{corner_path}`
      #TODO: Here we could also publish the results to opencpn.info...
    end
  end
  
  # Crops the insets of a specified chart and generates corner cut-outs
  # The chart has to be preprocessed already, the rotation is not done as part of this process
  def crop_insets(number)
    jpg_path = $jpg_path.gsub("{CHART_NUMBER}", number.to_s)
    preprocessed_jpg_path = $preprocessed_jpg_path.gsub("{CHART_NUMBER}", number.to_s)
    
    res = $dbh.query("SELECT * FROM ocpn_nga_charts WHERE number=#{number}")

    while row = res.fetch_hash do
      puts "Cropping insets and generating their corners for chart #{row["number"]}"
      
      # If rotated, use preprocessed JPG
      if (row["prerotate"].to_i != 0)
        jpg = preprocessed_jpg_path
      else
        jpg = jpg_path
      end
    end
    res = $dbh.query("SELECT *, (SELECT MIN(x) FROM ocpn_nga_kap_point WHERE point_type='CROP' AND active=1 AND kap_id=k.kap_id) AS x, (SELECT MAX(x) FROM ocpn_nga_kap_point WHERE point_type='CROP' AND active=1 AND kap_id=k.kap_id) AS x1, (SELECT MIN(y) FROM ocpn_nga_kap_point WHERE point_type='CROP' AND active=1 AND kap_id=k.kap_id) AS y, (SELECT MAX(y) FROM ocpn_nga_kap_point WHERE point_type='CROP' AND active=1 AND kap_id=k.kap_id) AS y1 FROM ocpn_nga_kap k WHERE bsb_type!='BASE' AND active=1 AND number=#{number}")
    while row = res.fetch_hash do
      corner_size = row["cornersize"]
      puts corner_size
      # check whether the data entered are ok
      if(row["x"].to_i >= 0 && row["y"].to_i >= 0 && row["x1"].to_i > row["x"].to_i && row["y1"].to_i > row["y"].to_i)
        inset_path = $inset_path.gsub("{CHART_NUMBER}", number.to_s).gsub("{INSET}", row["inset_id"])
        `#{$convert_command} #{jpg} -crop #{row["x1"].to_i - row["x"].to_i}x#{row["y1"].to_i - row["y"].to_i}+#{row["x"]}+#{row["y"]} #{inset_path}`
      
        # create corner cut-outs
        corner_path = $corner_path.gsub("{CHART_NUMBER}", number.to_s).gsub("{INSET}", row["inset_id"]).gsub("{CORNER}", 'sw')
        `#{$convert_command} #{inset_path} -gravity SouthWest -crop #{corner_size}x#{corner_size}+0+0 -depth 8 -type Palette -colors 32 png8:#{corner_path}`
        corner_path = $corner_path.gsub("{CHART_NUMBER}", number.to_s).gsub("{INSET}", row["inset_id"]).gsub("{CORNER}", 'nw')
        `#{$convert_command} #{inset_path} -gravity NorthWest -crop #{corner_size}x#{corner_size}+0+0 -depth 8 -type Palette -colors 32 png8:#{corner_path}`
        corner_path = $corner_path.gsub("{CHART_NUMBER}", number.to_s).gsub("{INSET}", row["inset_id"]).gsub("{CORNER}", 'ne')
        `#{$convert_command} #{inset_path} -gravity NorthEast -crop #{corner_size}x#{corner_size}+0+0 -depth 8 -type Palette -colors 32 png8:#{corner_path}`
        corner_path = $corner_path.gsub("{CHART_NUMBER}", number.to_s).gsub("{INSET}", row["inset_id"]).gsub("{CORNER}", 'se')
        `#{$convert_command} #{inset_path} -gravity SouthEast -crop #{corner_size}x#{corner_size}+0+0 -depth 8 -type Palette -colors 32 png8:#{corner_path}`
  
        $dbh.query("UPDATE ocpn_nga_kap SET cropped=CURRENT_TIMESTAMP() WHERE kap_id=#{row["kap_id"]}")
      end
    end
  end
  
  # Imports the PLY polygon from a GPX file 
  def gpx_to_ply(number, gpx_file)
    
    # load from db
    @number =  number
    load_from_db
    
    if !@kaps[0].gpx_to_ply(gpx_file)
      puts "Error"
      return
    end
    res = $dbh.query("SELECT kap_id, status_id FROM ocpn_nga_kap WHERE bsb_type = 'BASE' AND active = 1 AND number = #{number}")
    if (row = res.fetch_hash)
      kap_id = row["kap_id"]
      status_id = row["status_id"].to_i
    else
      puts "Can't find a KAP"
      break
    end
    res = $dbh.query("UPDATE ocpn_nga_kap_point SET active = 0 WHERE point_type = 'PLY' AND active = 1 AND kap_id = #{kap_id}")
    seq = 0
    @kaps[0].ply.each{|ply|
      seq += 1
      #TODO: we do not have the user id, so we use 1 as "system"
      res = $dbh.query("INSERT INTO ocpn_nga_kap_point (kap_id, latitude, longitude, x, y, point_type, created_by, created, sequence, active) VALUES (#{kap_id}, #{ply.latitude}, #{ply.longitude}, NULL, NULL, 'PLY', 1, CURRENT_TIMESTAMP(), #{seq}, 1)")
    }
    if (status_id == 8 || status_id == 1) #we want to keep the chart status, if it has insets, so change it just in case only problem is it needed the PLYs
      status_id = 18
    end
    res = $dbh.query("UPDATE ocpn_nga_kap SET status_id = #{status_id}, changed = CURRENT_TIMESTAMP(), kap_generated = NULL WHERE bsb_type = 'BASE' AND active = 1 AND number = #{number}")
    res = $dbh.query("UPDATE ocpn_nga_charts SET status_id = #{status_id} WHERE number = #{number}")
  end
  
  # Preprocesses the chart
  # If needed, the chart is rotated by a multiple of 90 degrees
  # The thumbnails and corner images are generated
  def preprocess(number)
    jpg_path = $jpg_path.gsub("{CHART_NUMBER}", number.to_s)
    preprocessed_jpg_path = $preprocessed_jpg_path.gsub("{CHART_NUMBER}", number.to_s)
    
    res = $dbh.query("SELECT * FROM ocpn_nga_charts WHERE number=#{number}")

    while row = res.fetch_hash do
      puts "Preprocessing chart #{row["number"]}"
      
      # Preprocess
      # rotate if needed
      if (row["prerotate"] != 0)
        `#{$convert_command} #{jpg_path} -rotate #{row["prerotate"]} #{preprocessed_jpg_path}`
        jpg = preprocessed_jpg_path
      else
        jpg = jpg_path
      end
      # create zl0 thumbnail
      thumbnail_path = $thumbnail_path.gsub("{CHART_NUMBER}", number.to_s).gsub("{ZOOM_LEVEL}", '0')
      `#{$convert_command} #{jpg} -resize 0.8% #{thumbnail_path}`
      # create zl2 thumbnail
      thumbnail_path = $thumbnail_path.gsub("{CHART_NUMBER}", number.to_s).gsub("{ZOOM_LEVEL}", '2')
      `#{$convert_command} #{jpg} -resize 3% #{thumbnail_path}`
      # generate corners
      generate_corners(number)
      #TODO: Here we could also publish the results to opencpn.info...
    end
  end
  
  # Produces the chart
  def produce(number, percent, autorotate = false)
    output_dir = $output_dir.gsub("{CHART_NUMBER}", number.to_s)
    
    # load from db
    @number =  number
    load_from_db
    
    puts "Pre-rotation: #{@pre_rotate}"
    if(@pre_rotate == 0)
      jpg_path = $jpg_path.gsub("{CHART_NUMBER}", number.to_s)
    else
      jpg_path = $preprocessed_jpg_path.gsub("{CHART_NUMBER}", number.to_s)
    end

    rotation = @kaps[0].suggest_rotation
    puts "Suggested rotation: #{rotation}";
    puts "Original calibration:"
    puts @kaps[0].inspect
        
    # resize header
    #@kaps[0].resize_to_percent(percent)
    
    # create resized image 
    if (autorotate && rotation.abs > $skew_angle) #if the skew is smaller than $skew_angle, we rotate the chart
      @kaps[0].rotate(rotation)
      puts "Rotated kap:"
      puts @kaps[0].inspect
      @kaps[0].resize_to_percent(percent)
      puts "Resized kap:"
      puts @kaps[0].inspect
      `#{$convert_command} #{jpg_path} -limit memory 2048MB -level 5% -resize #{percent}% -rotate #{rotation} -despeckle -crop #{@kaps[0].bsb_ra[0]}x#{@kaps[0].bsb_ra[1]}+0+0 -depth 8 -colors 32 -type Palette png8:#{output_dir}/#{number}.png`
    else
      @kaps[0].resize_to_percent(percent)
      `#{$convert_command} #{jpg_path} -limit memory 2048MB -level 5% -resize #{percent}% -despeckle -crop #{@kaps[0].bsb_ra[0]}x#{@kaps[0].bsb_ra[1]}+0+0 -depth 8 -colors 32 -type Palette png8:#{output_dir}/#{number}.png`
    end
    
    # create BSB
    File.open("#{output_dir}/#{number}.bsb", "w") {|file|
      file << @bsb
      file.close
      }
    # produce the KAP
    File.open("#{output_dir}/#{number}.txt", "w") {|file|
      file << @kaps[0]
      file.close
      }
    `#{$imgkap_command} -p NONE -n #{output_dir}/#{number}.png #{output_dir}/#{number}.txt #{output_dir}/#{number}.kap`
    # save GPX with the boundaries
    @kaps[0].ply_to_gpx("#{output_dir}/#{number}.gpx")
    $dbh.query("UPDATE ocpn_nga_kap SET kap_generated = CURRENT_TIMESTAMP() WHERE active = 1 AND bsb_type = 'BASE' AND number=#{@number}")
  end
end

begin
  # connect to the MySQL server
  $dbh = Mysql.connect($db_host, $db_username, $db_password, $db_database)
  # get server version string and display it
  #puts "Server version: " + $dbh.get_server_info
  # check the lock nd exit if it exists
  
  options = {}

  optparse = OptionParser.new do|opts|
  # Set a banner, displayed at the top
  # of the help screen.
    opts.banner = "Usage: kaptool.rb [options] <chart number>"
  
    # Define the options, and what they do
    options[:verbose] = false
    opts.on( '-v', '--verbose', 'Output more information' ) do
      options[:verbose] = true
    end
  
    options[:action] = 'PRODNEW'
    opts.on( '-a', '--action ACTION', "What to do:\n       PRODNEW - generate all new KAPs from the DB (default)\n       KAP - generate KAP\n       PLY - define polygon\n       PREPROCESS - rotate chart 90/180/270 degrees, create thumbnails, generate corners\n       CORNERS - generate corners\n       CROP - crops the insets and generates their corners" ) do|action|
      options[:action] = action.upcase
    end
    
    options[:polygon] = nil
    opts.on( '-p', '--polygon FILE', 'Border polygon definition GPX file' ) do|file|
      options[:polygon] = file
    end
  
    # This displays the help screen, all programs are
    # assumed to have this option.
    opts.on( '-h', '--help', 'Display this screen' ) do
      puts opts
      exit
    end
  end
  
  optparse.parse!
  
  if (options[:action] == 'PRODNEW')
    if (File.exists?($lock_path))
      puts "KAPTool already running, exiting."
      Process.exit
    end
    f = File.new($lock_path,"w")
    begin
      f.puts "Locked at #{Time.now.asctime}"
    ensure
      f.close
    end
    
    Chart.process_new_base_calibrations
    Chart.process_new_insets
    
    # delete lock
    if (File.exists?($lock_path))
      File.unlink($lock_path)
    end
  else
    if (ARGV.length != 1)
      puts "Usage: kaptool.rb [options] <chart number>"
      exit
    end
    
    ARGV.each do|number|
      if (Util::numeric?(number))
        puts "Crunching chart #{number}..."
        case options[:action]
        when 'KAP'
          chart = Chart.new
          chart.produce(number, $kap_size_percent, $kap_autorotate)
        when 'PLY'
          chart = Chart.new
          chart.gpx_to_ply(number, options[:polygon])
        when 'PREPROCESS'
          chart = Chart.new
          chart.preprocess(number)
        when 'CORNERS'
          chart = Chart.new
          chart.generate_corners(number)
        when 'CROP'
          chart = Chart.new
          chart.crop_insets(number)
        else
          puts "Action #{options[:action]} unknown, exiting..."
          exit
        end
      else
        puts "Argument #{number} is not a number, exiting..."
        exit
      end
    end
  end

rescue Mysql::Error => e
  puts "Error code: #{e.errno}"
  puts "Error message: #{e.error}"
  puts "Error SQLSTATE: #{e.sqlstate}" if e.respond_to?("sqlstate")
  if (File.exists?($lock_path))
    File.unlink($lock_path)
  end
ensure
  # disconnect from server
  $dbh.close if $dbh
end
