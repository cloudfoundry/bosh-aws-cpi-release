require 'JSON'

class Renderer
  def self.render(spec, template_name)
    evaluation_context = EvaluationContext.new(spec)
    template = ERB.new(File.read(template_name))
    template.result(evaluation_context.get_binding)
  end
end