require "telegram_bot"
require "telegram_markd"
require "schedule"

macro t(key, options = nil, locale = "zh-hans")
  I18n.translate({{key}}, {{options}}, {{locale}})
end

def escape_markdown(text : String) : String
  escape_all text, "\\\\", ["[", "]", "*", "_", "`"]
end

def schedule(time, &block)
  Schedule.after time, &block
end

macro def_text(method_name = "create_text", *args)
  {{ args_exp_s = args.join(", ") }}

  def {{method_name.id}}(_group_id, {{args_exp_s.id}}{% if args.size > 0 %},{% end %} group_name : String? = nil)
    %text = {{yield}}
    wrapper_title %text
  end
end

macro def_markup(method_name = "create_markup", *args)
  {{ args_exp_s = args.join(", ") }}

  def {{method_name.id}}(_group_id, {{args_exp_s.id}}{% if args.size > 0 %},{% end %} group_name : String? = nil, from_nav : Bool = false)
    _markup = Markup.new

    {{yield}}

    if from_nav
      _markup << [Button.new(text: "返回主导航", callback_data: "Navigation:main")]
    end

    _markup
  end
end

macro render(str, vars, vals)
  {{str}}.
  {% for var, i in vars %}
    gsub(/\\{\\{\s?{{var.id}}\s?\}\}/, {{vals}}[{{i}}])
      {% if i < vars.size - 1 %}.{% end %}
  {% end %}
end

def from_group_chat?(msg)
  case msg.chat.type
  when "supergroup"
    true
  when "group"
    true
  else
    false
  end
end

def from_supergroup?(msg)
  msg.chat.type == "supergroup"
end

def from_private_chat?(msg)
  msg.chat.type == "private"
end

def fullname(user) : String
  name = user.first_name
  last_name = user.last_name
  name = last_name ? "#{name} #{last_name}" : name
  name || "[Unnamed]"
end

module Policr
  DEFAULT_TORTURE_SEC = 55 # 默认验证等待时长（秒）

  alias Button = TelegramBot::InlineKeyboardButton
  alias Markup = TelegramBot::InlineKeyboardMarkup

  class Bot < TelegramBot::Bot
    private macro regall(cls_list)
      {% for cls in cls_list %}
        midreg {{cls}}
      {% end %}
    end

    include TelegramBot::CmdHandler

    getter self_id : Int32
    getter handlers = Hash(String, Handler).new
    getter callbackers = Hash(String, Callbacker).new
    getter commanders = Hash(String, Commander).new
    getter command_names = Set(String).new

    getter snapshot_channel : String
    getter voting_channel : String
    getter username : String
    getter owner_id : String
    getter community_group_id : Int64

    def initialize(username, token, @owner_id, community_group_id, logger, @snapshot_channel, @voting_channel)
      super(username, token, logger: logger)
      @username = username
      @community_group_id = community_group_id.to_i64

      me = get_me || raise Exception.new("Failed to get bot data")
      @self_id = me["id"].as_i

      # 注册消息处理模块
      regall [
        SelfLeftHandler,
        # 置顶分割
        UserJoinHandler,
        BotJoinHandler,
        SelfJoinHandler,
        LeftGroupHandler,
        UnverifiedMessageHandler,
        FromSettingHandler,
        WelcomeSettingHandler,
        TortureTimeSettingHandler,
        CustomHandler,
        HalalMessageHandler,
        PrivateForwardHandler,
        ReportDetailHandler,
        AddRuleHandler,
        MaxLengthHandler,
        MaxLengthSettingHandler,
        CleanModeTimeSettingHandler,
        FormatLimitHandler,
        FormatLimitSettingHandler,
        PrivateChatReplyHandler,
        AppealReplyHandler,
        TemplateSettingHandler,
        HalalCaptionHandler,
        AddVotingApplyQuizHandler,
        UpdateVotingApplyQuizQuestionHandler,
        UpdateChatTitleHandler,
        UpdateChatPhotoHandler,
        PinnedMessageHandler,
        UpdateRuleHandler,
        BlockedContentHandler,
        AddGlobalRuleHandler,
        BlockedNicknameHandler,
        # 置底分割
        PrivateChatHandler,
      ]

      # 注册回调模块
      regall [
        TortureCallbacker,
        BanedMenuCallbacker,
        BotJoinCallbacker,
        SelfJoinCallbacker,
        FromCallbacker,
        TortureTimeCallbacker,
        CustomCallbacker,
        SettingsCallbacker,
        ReportCallbacker,
        VotingCallbacker,
        CleanModeCallbacker,
        DelayTimeCallbacker,
        SubfunctionsCallbacker,
        PrivateForwardCallbacker,
        PrivateForwardReportCallbacker,
        StrictModeCallbacker,
        MaxLengthCallbacker,
        WelcomeCallbacker,
        LanguageCallbacker,
        AntiServiceMsgCallbacker,
        FormatLimitCallbacker,
        FromSettingCallbacker,
        AppealCallbacker,
        AfterwardsCallbacker,
        TemplateCallbacker,
        ManageCallbacker,
        NavigationCallbacker,
        VotingApplyQuizCallbacker,
        BlockRuleCallbacker,
        GlobalBlockRuleCallbacker,
        GlobalRuleFlagsCallbacker,
        HitRuleCallbacker,
      ]

      # 注册指令模块
      regall [
        StartCommander,
        PingCommander,
        FromCommander,
        WelcomeCommander,
        TortureTimeCommander,
        CustomCommander,
        ReportCommander,
        SettingsCommander,
        CleanModeCommander,
        SubfunctionsCommander,
        StrictModeCommander,
        LanguageCommander,
        AntiServiceMsgCommander,
        TemplateCommander,
        AppealCommander,
        NavigationCommander,
        VotingApplyCommander,
        GlobalRuleFlagsCommander,
      ]

      commanders.each do |_, command|
        cmd command.name do |msg|
          command.handle(msg, from_nav: false)
        end
      end
    end

    def handle(msg : TelegramBot::Message)
      Cache.put_serve_group(msg, self) if from_group_chat?(msg)

      super

      state = Hash(Symbol, StateValueType).new
      handlers.each do |_, handler|
        handler.registry(msg, state)
      end
    end

    def handle_edited(msg : TelegramBot::Message)
      state = Hash(Symbol, StateValueType).new
      handlers.each do |_, handler|
        handler.registry(msg, state, from_edit: true)
      end
    end

    def handle(query : TelegramBot::CallbackQuery)
      _handle = ->(data : String, message : TelegramBot::Message) {
        args = data.split(":")
        if args.size < 2
          answer_callback_query(query.id, text: t("invalid_callback"))
          return
        end

        call_name = args[0]

        callbackers.each do |_, cb|
          cb.handle(query, message, args[1..]) if cb.match?(call_name)
        end
      }
      if (data = query.data) && (message = query.message)
        _handle.call(data, message)
      end
    end

    def is_admin?(chat_id, user_id, dirty = true)
      has_permission?(chat_id, user_id, :admin, dirty)
    end

    def has_permission?(chat_id, user_id, role, dirty = true) : Bool
      return false if chat_id > 0          # 私聊无权限
      if admins = Cache.get_admins chat_id # 从缓存中获取管理员列表
        tmp_filter_users = admins.select { |m| m.user.id == user_id }
        noperm = tmp_filter_users.size == 0
        status = noperm ? nil : tmp_filter_users[0].status

        is_creator = status == "creator"
        result =
          !noperm &&
            case role
            when :creator
              is_creator
            when :admin
              is_creator || status == "administrator"
            else
              false
            end

        # 异步更新缓存
        spawn { refresh_admins chat_id } if dirty
        result
      else # 没有获得管理员列表，缓存并递归
        Cache.set_admins chat_id, get_chat_administrators(chat_id)
        has_permission?(chat_id, user_id, role, dirty: false)
      end
    end

    def refresh_admins(chat_id)
      Cache.set_admins chat_id, get_chat_administrators(chat_id)
    end

    def log(text)
      logger.info text
    end

    def debug(text)
      logger.debug text
    end

    def token
      @token
    end

    def derestrict(chat_id : Int64, user_id : Int32)
      restrict_chat_member(
        chat_id,
        user_id,
        can_send_messages: true,
        can_send_media_messages: true,
        can_send_other_messages: true,
        can_add_web_page_previews: true
      )
    end

    def restrict(chat_id : Int64, user_id : Int32)
      restrict_chat_member(
        chat_id,
        user_id,
        can_send_messages: false
      )
    end

    def parse_error(ex : TelegramBot::APIException)
      code = -1
      reason = "Unknown"

      if data = ex.data
        reason = data["description"] || reason
        code = data["error_code"]? || code
      end
      {code, reason.to_s}
    end

    private def parse_text(parse_mode : String?, text : String)
      parse_mode, text =
        if parse_mode
          case parse_mode.downcase
          when "markdown"
            {"HTML", TelegramMarkd.to_html text}
          when "html"
            {"HTML", text}
          else
            {nil, text}
          end
        else
          {nil, text}
        end
      {parse_mode, text}
    end

    def send_message(chat_id : Int | String,
                     text : String,
                     parse_mode : String? = "Markdown",
                     disable_web_page_preview : Bool? = true,
                     disable_notification : Bool? = nil,
                     reply_to_message_id : Int32? = nil,
                     reply_markup : ReplyMarkup = nil) : TelegramBot::Message?
      parse_mode, text = parse_text parse_mode, text
      disable_notification =
        if disable_notification == nil && chat_id.is_a?(Int32 | Int64)
          if chat_id > 0 # 私聊开启声音
            false
          else
            Model::Toggle.enabled? chat_id, ToggleTarget::SlientMode
          end
        else
          disable_notification
        end
      super(
        chat_id: chat_id,
        text: text,
        parse_mode: parse_mode,
        disable_web_page_preview: disable_web_page_preview,
        disable_notification: disable_notification,
        reply_to_message_id: reply_to_message_id,
        reply_markup: reply_markup
      )
    end

    def edit_message_text(chat_id : Int | String | Nil = nil,
                          message_id : Int32? = nil,
                          inline_message_id : String? = nil,
                          text : String? = nil,
                          parse_mode : String? = "Markdown",
                          disable_web_page_preview : Bool? = true,
                          reply_markup : TelegramBot::InlineKeyboardMarkup? = nil) : TelegramBot::Message | Bool | Nil
      parse_mode, text = parse_text parse_mode, text || ""
      super(
        chat_id: chat_id,
        message_id: message_id,
        inline_message_id: inline_message_id,
        text: text,
        parse_mode: parse_mode,
        disable_web_page_preview: disable_web_page_preview,
        reply_markup: reply_markup
      )
    end

    def send_photo(chat_id : Int | String,
                   photo : ::File | String,
                   caption : String? = nil,
                   parse_mode : String? = "Markdown",
                   disable_notification : Bool? = nil,
                   reply_to_message_id : Int32? = nil,
                   reply_markup : ReplyMarkup = nil) : TelegramBot::Message?
      parse_mode, caption = parse_text parse_mode, caption
      disable_notification =
        if disable_notification == nil && chat_id.is_a?(Int32 | Int64)
          if chat_id > 0 # 私聊开启声音
            false
          else
            Model::Toggle.enabled? chat_id, ToggleTarget::SlientMode
          end
        else
          disable_notification
        end
      super(
        chat_id: chat_id,
        photo: photo,
        caption: caption,
        parse_mode: parse_mode,
        disable_notification: disable_notification,
        reply_to_message_id: reply_to_message_id,
        reply_markup: reply_markup
      )
    end

    def send_sticker(chat_id : Int | String,
                     sticker : ::File | String,
                     disable_notification : Bool? = nil,
                     reply_to_message_id : Int32? = nil,
                     reply_markup : ReplyMarkup = nil) : TelegramBot::Message?
      disable_notification =
        if disable_notification == nil && chat_id.is_a?(Int32 | Int64)
          if chat_id > 0 # 私聊开启声音
            false
          else
            Model::Toggle.enabled? chat_id, ToggleTarget::SlientMode
          end
        else
          disable_notification
        end
      super(
        chat_id: chat_id,
        sticker: sticker,
        disable_notification: disable_notification,
        reply_to_message_id: reply_to_message_id,
        reply_markup: reply_markup
      )
    end

    NONE_FROM_USER = "Unknown"
    WELCOME_VARS   = ["fullname", "chatname", "mention", "userid"]

    def send_welcome(chat : TelegramBot::Chat, from_user : FromUser? = nil)
      chat_id = chat.id

      if (welcome = Model::Welcome.find_by_chat_id(chat_id)) &&
         (parsed = WelcomeContentParser.parse welcome.content)
        unless welcome.is_sticker_mode
          disable_link_preview = Model::Welcome.link_preview_disabled?(chat_id)
          text =
            parsed.content || "Warning: welcome content format is incorrect"
          chat_title = escape_markdown chat.title || "[Untitled]"
          text =
            if from_user
              vals = [from_user.fullname, chat_title, from_user.markdown_link, from_user.user_id]
              render text, {{ WELCOME_VARS }}, vals
            else
              vals = [NONE_FROM_USER, chat_title, NONE_FROM_USER, NONE_FROM_USER]
              render text, {{ WELCOME_VARS }}, vals
            end

          markup = Markup.new
          if parsed.buttons.size > 0
            parsed.buttons.each do |button|
              markup << [Button.new(text: button.text, url: button.link)]
            end
          end

          spawn {
            sended_msg = send_message(
              chat_id,
              text: text,
              reply_markup: markup,
              disable_web_page_preview: disable_link_preview
            )

            if sended_msg # 根据设置延迟清理
              _del_msg_id = sended_msg.message_id
              Model::CleanMode.working(chat_id, CleanDeleteTarget::Welcome) do
                delete_message(chat_id, _del_msg_id)
              end
            end
          }
        else # 贴纸模式
          if sticker = welcome.sticker_file_id
            markup = Markup.new
            btn_text = t "welcome.sticker_mode_btn"
            markup << [Button.new(text: btn_text, url: "https://t.me/#{username}?start=welcome_#{welcome.id}")]
            spawn {
              sended_msg = send_sticker(
                chat_id,
                sticker: sticker.not_nil!,
                reply_markup: markup
              )

              if sended_msg # 根据设置延迟清理
                _del_msg_id = sended_msg.message_id
                Model::CleanMode.working(chat_id, CleanDeleteTarget::Welcome) do
                  delete_message(chat_id, _del_msg_id)
                end
              end
            }
          end
        end
      else
        spawn send_message(chat_id, "Warning: welcome content format is incorrect")
      end
    end
  end
end
