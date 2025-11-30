defmodule ImgdWeb.PageController do
  use ImgdWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
