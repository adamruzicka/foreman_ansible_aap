# frozen_string_literal: true

require 'test_plugin_helper'

class ForemanAnsibleAapJobInvocationsControllerTest < ActionController::TestCase
  tests JobInvocationsController

  test 'authorized users see a direct AAP job link on invocation detail' do
    invocation = FactoryBot.create(:job_invocation, :with_template, :with_task)
    invocation.update!(ansible_execution_driver: 'aap')
    task_group = JobInvocationTaskGroup.create!
    invocation.update!(task_group: task_group)
    invocation.task.add_missing_task_groups(task_group)
    ForemanAnsibleAap::Execution.create!(
      job_invocation: invocation,
      aap_job_id: 91,
      aap_job_url: 'https://aap.example.test/api/controller/v2/jobs/91/'
    )

    get :show, params: { id: invocation.id }, session: set_session_user

    assert_response :success
    assert_includes response.body, 'AAP job 91'
    assert_includes response.body, 'https://aap.example.test/api/controller/v2/jobs/91/'
  end
end
