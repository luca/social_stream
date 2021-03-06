module SocialStream
  module Documents
    class Engine < Rails::Engine
    
      initializer "social_stream-documents.register_mime_types" do
        # Documents
        Mime::Type.register "text/plain", :txt
        Mime::Type.register "application/x-rar", :rar
        Mime::Type.register "application/postscript", :ps, [ "application/ps" ]
        Mime::Type.register "application/vnd.oasis.opendocument.text", :odt
        Mime::Type.register "application/vnd.oasis.opendocument.presentation", :odp
        Mime::Type.register "application/vnd.oasis.opendocument.presentation", :ods
        Mime::Type.register "application/vnd.ms-word", :doc, [ "application/msword" ]
        Mime::Type.register "application/vnd.ms-powerpoint", :ppt, [ "application/mspowerpoint" ]
        Mime::Type.register "application/vnd.ms-excel", :xls, [ "application/msexcel" ]
        Mime::Type.register "application/rtf", :rtf
        Mime::Type.register "application/vnd.scribus", :sla
        # These are already defined in Rails 3.2
        unless defined? Mime::ZIP
          Mime::Type.register "application/zip", :zip
        end
        unless defined? Mime::PDF
          Mime::Type.register "application/pdf", :pdf
        end
       
        # Picture
        Mime::Type.register "image/x-xcf", :xcf
        # These are already defined in Rails 3.2
        unless defined? Mime::JPEG
          Mime::Type.register "image/jpeg", :jpeg, ["image/pjpeg","image/jpg"]
        end
        unless defined? Mime::GIF
          Mime::Type.register "image/gif",  :gif
        end
        unless defined? Mime::PNG
          Mime::Type.register "image/png",  :png,  [ "image/x-png" ]
        end
        unless defined? Mime::BMP
          Mime::Type.register "image/bmp",  :bmp, [ "image/x-ms-bmp" ]
        else
          # Manually register synonym
          Mime::BMP.instance_variable_get("@synonyms") << "image/x-ms-bmp"
          Mime::LOOKUP["image/x-ms-bmp"] = Mime::BMP
        end
        
        # Audio
        Mime::Type.register "audio/x-wav", :wav, [ "audio/wav" ]
        
        Mime::Type.register "audio/x-vorbis+ogg", :ogg, [ "application/ogg" ]
        # These are already defined in Rails 3.2
        # MPEG is currently reserved to 'video/mpeg'
        unless defined? Mime::MP3
          Mime::Type.register "audio/mpeg", :mp3
        end
        
        # Video
        Mime::Type.register "video/x-flv", :flv
      end

      initializer "social_stream-documents.toolbar_config", :after=>"social_stream-base.toolbar_config" do
        SocialStream::ToolbarConfig.module_eval do
          include SocialStream::ToolbarConfig::Documents
        end
      end
    end
  end
end
