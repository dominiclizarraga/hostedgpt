require "test_helper"

class GetNextAIMessageJobOpenaiTest < ActiveJob::TestCase
  setup do
    @conversation = conversations(:greeting)
    @user = @conversation.user
    @assistant = @conversation.assistant
    @conversation.messages.create! role: :user, content_text: "Still there?", assistant: @assistant
    @assistant.language_model.update!(supports_tools: false) # this will change the TestClient response so we want to be selective about this
    @message = @conversation.latest_message_for_version(:latest)
    @test_client = TestClient::OpenAI.new(access_token: "abc")
  end

  test "populates the latest message from the assistant" do
    assert_no_difference "@conversation.messages.reload.length" do
      TestClient::OpenAI.stub :text, "Hello" do
        assert GetNextAIMessageJob.perform_now(@user.id, @message.id, @assistant.id)
      end
    end

    assert_equal "Hello", @conversation.latest_message_for_version(:latest).content_text
  end

  test "populates a tool response call from the assistant and creates additional tool messages" do
    @assistant.language_model.update!(supports_tools: true)

    assert_difference "@conversation.messages.reload.length", 2 do
      TestClient::OpenAI.stub :function, "helloworld_hi" do
        TestClient::OpenAI.stub :arguments, {:name=>"Keith"} do
          assert GetNextAIMessageJob.perform_now(@user.id, @message.id, @assistant.id)
        end
      end
    end

    @message.reload
    assert @message.content_text.blank?
    assert @message.tool_call_id.nil?
    assert @message.content_tool_calls.present?, "Assistant should have decided to call a tool"

    @new_messages = @conversation.messages.where("id > ?", @message.id).order(:created_at)

    first_new_message = @new_messages.first
    assert first_new_message.tool?
    assert_equal "Hello, Keith!".to_json, first_new_message.content_text, "First new message should have the result of calling the tool"
    assert first_new_message.tool_call_id.present?
    assert first_new_message.content_tool_calls.present?
    assert_equal @message.content_tool_calls.dig(0, :id), first_new_message.tool_call_id, "ID of tool execution should have matched decision to call the tool"
    assert first_new_message.finished?, "This message SHOULD HAVE been considered finished"

    # second
    second_new_message = @new_messages.second
    assert second_new_message.assistant?, "Second new message should be queued up for the assistant to reply"
    assert second_new_message.content_text.nil?, "The content should be nil to indicate that it hasn't even started processing"
    assert second_new_message.tool_call_id.nil?
    assert second_new_message.content_tool_calls.blank?
    refute second_new_message.finished?, "This message SHOULD NOT be considered finished yet"
  end

  test "returns early if the message id was invalid" do
    refute GetNextAIMessageJob.perform_now(@user.id, 0, @assistant.id)
  end

  test "returns early if the assistant id was invalid" do
    refute GetNextAIMessageJob.perform_now(@user.id, @message.id, 0)
  end

  test "returns early if the message was already generated" do
    @message.update!(content_text: "Hello")
    refute GetNextAIMessageJob.perform_now(@user.id, @message.id, @assistant.id)
  end

  test "returns early if the user has replied after this" do
    @conversation.messages.create! role: :user, content_text: "Ignore that, new question:", assistant: @assistant
    refute GetNextAIMessageJob.perform_now(@user.id, @message.id, @assistant.id)
  end

  test "when openai key is blank, a nice error message is displayed" do
    stub_features(default_llm_keys: false) do
      api_service = @assistant.language_model.api_service
      api_service.update!(token: "")

      assert GetNextAIMessageJob.perform_now(@user.id, @message.id, @assistant.id)
      assert_includes @conversation.latest_message_for_version(:latest).content_text, "need to enter a valid API key for OpenAI"
    end
  end

  test "when API response key is missing, a nice error message is displayed" do
    TestClient::OpenAI.stub :text, "" do
      assert GetNextAIMessageJob.perform_now(@user.id, @message.id, @assistant.id)
      assert_includes @conversation.latest_message_for_version(:latest).content_text, "a blank response"
    end
  end
end
